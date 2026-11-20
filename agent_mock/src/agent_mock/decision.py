"""Decisão determinística do agente: uma ação por evento.

| Intenção | Ferramenta | Resultado | Ação |
| - | - | - | - |
| agradecimento | nenhuma | | resolve, motivo lojista_confirmou |
| saudacao | nenhuma | | reply de boas-vindas pedindo o assunto |
| transacao sem TX | nenhuma | | reply pedindo o id da transação |
| transacao com TX | consultar_transacao | aprovada, estornada | reply com status, valor e data |
| | | contestada, nao_encontrada | escalate |
| repasse | consultar_repasse | pago, agendado | reply com valor e data |
| | | nao_encontrado | escalate |
| taxas | consultar_taxas | tabela da marca | reply com as taxas |
| maquininha sem SN | nenhuma | | reply pedindo o número de série |
| maquininha com SN | status_maquininha | online, offline | reply com passos de reinício ou de conexão |
| | | defeito | escalate para troca |
| desconhecida | nenhuma | | escalate, motivo intencao_nao_identificada |

A decisão depende só do texto, da marca e do locale; os horários das ferramentas ficam fora da
comparação. Os textos ao lojista seguem o locale da marca; resumo, tentativas e próximo passo do
escalate são para o analista e ficam em português.
"""

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date

from agent_mock import clock, entities, intents, tools
from agent_mock.events import Event

REPLIES = {
    "pt-BR": {
        "saudacao": "Olá! Sou o assistente virtual. Me conte o assunto do atendimento: transação, repasse, taxas ou maquininha.",
        "pedir_transacao": "Para consultar a transação, me envie o id dela: TX seguido de 10 dígitos, como aparece no extrato.",
        "aprovada": "A transação {id} de {valor}, de {data}, está aprovada.",
        "estornada": "A transação {id} de {valor}, de {data}, foi estornada. O valor volta ao cliente pelo mesmo meio de pagamento.",
        "pago": "O repasse de {valor} foi pago em {data}.",
        "agendado": "O repasse de {valor} está agendado para {data}.",
        "taxas": "As taxas da sua conta são: débito {debito}%, crédito à vista {credito_a_vista}%, crédito em 12x {credito_12x}% e Pix {pix}%.",
        "pedir_serie": "Para verificar a maquininha, me envie o número de série: SN seguido de 8 dígitos, na etiqueta de trás do aparelho.",
        "online": "A maquininha {serie} está online. Desligue e ligue de novo, segurando o botão de energia por 10 segundos; se o problema continuar, me avise.",
        "offline": "A maquininha {serie} está offline. Confira o Wi-Fi ou o chip, ligue e desligue o modo avião e tente de novo.",
    },
    "en-US": {
        "saudacao": "Hi! I am the virtual assistant. Tell me what you need help with: transaction, payout, fees or card reader.",
        "pedir_transacao": "To look up the transaction, send me its id: TX followed by 10 digits, as shown on your statement.",
        "aprovada": "Transaction {id} for {valor} on {data} is approved.",
        "estornada": "Transaction {id} for {valor} on {data} was refunded. The amount goes back to the customer through the same payment method.",
        "pago": "Your payout of {valor} was paid on {data}.",
        "agendado": "Your payout of {valor} is scheduled for {data}.",
        "taxas": "Your account fees are: debit {debito}%, credit {credito_a_vista}%, credit in 12 installments {credito_12x}% and instant payment {pix}%.",
        "pedir_serie": "To check your card reader, send me its serial number: SN followed by 8 digits, on the label on the back.",
        "online": "Card reader {serie} is online. Turn it off and on again, holding the power button for 10 seconds; if the problem continues, let me know.",
        "offline": "Card reader {serie} is offline. Check the Wi-Fi or SIM card, toggle airplane mode and try again.",
    },
}

# Próximo passo e confiança fixos por motivo de escalação.
ESCALATIONS = {
    "transacao_contestada": ("Abrir a contestação da transação e informar o prazo ao lojista", 0.6),
    "transacao_nao_localizada": ("Localizar a transação no sistema de pagamentos e confirmar com o lojista", 0.4),
    "repasse_nao_localizado": ("Verificar o repasse no sistema financeiro e informar o prazo ao lojista", 0.35),
    "maquininha_com_defeito": ("Enviar uma maquininha de troca ao lojista", 0.7),
    "intencao_nao_identificada": ("Ler a mensagem e identificar a necessidade do lojista", 0.2),
}

NEGATIVE = {
    "pt-BR": [
        "absurdo", "duas vezes", "ainda nao", "nao caiu", "nao aparece", "nao liga", "erro", "diferente", "pessimo",
        "reclamacao", "urgente",
    ],
    "en-US": [
        "ridiculous", "twice", "not arrived", "missing", "not turned on", "error", "different", "terrible",
        "complaint", "urgent",
    ],
}

RESOLVE_REASON = "lojista_confirmou"


@dataclass(frozen=True)
class Decision:
    """Tipo da ação, campos próprios do tipo e registro das ferramentas, na ordem das chamadas."""

    type: str
    fields: dict
    tools: list[dict] = field(default_factory=list)
    intent: str = intents.UNKNOWN
    entities: dict = field(default_factory=dict)


def decided_text(event: Event, context: dict) -> str:
    """Texto da mensagem com a sequence do evento no contexto; o texto do evento quando ela não aparece."""
    for message in context.get("messages", []):
        if message.get("sequence") == event.sequence:
            return message["text"]
    return event.text


def sentiment(text: str, locale: str) -> str:
    tokens = intents.words(text)
    for expression in NEGATIVE[locale]:
        phrase = intents.words(expression)
        if any(tokens[index:index + len(phrase)] == phrase for index in range(len(tokens))):
            return "negative"
    return "neutral"


def money(value: str, locale: str) -> str:
    integer, cents = value.split(".")
    grouped = f"{int(integer):,}"
    if locale == "pt-BR":
        return f"R$ {grouped.replace(',', '.')},{cents}"
    return f"${grouped}.{cents}"


def day(value: str, locale: str) -> str:
    parsed = date.fromisoformat(value)
    return parsed.strftime("%d/%m/%Y") if locale == "pt-BR" else parsed.strftime("%m/%d/%Y")


def percent(value: str, locale: str) -> str:
    return value.replace(".", ",") if locale == "pt-BR" else value


def decide(event: Event, context: dict, locale: str, stamp: Callable[[], str] = clock.stamp) -> Decision:
    """Decisão para o evento, com o texto decidido pelo contexto."""
    text = decided_text(event, context)
    intent = intents.classify(text, locale)
    found = entities.extract(text, locale)
    return _Decider(text, intent, found, event.brand, locale, stamp).decide()


class _Decider:
    def __init__(self, text, intent, found, brand, locale, stamp):
        self.text = text
        self.intent = intent
        self.entities = found
        self.brand = brand
        self.locale = locale
        self.stamp = stamp
        self.calls: list[dict] = []

    def decide(self) -> Decision:
        handler = {
            "agradecimento": self.thanks,
            "saudacao": lambda: self.reply("saudacao"),
            "transacao": self.transaction,
            "repasse": self.payout,
            "taxas": self.fees,
            "maquininha": self.reader,
        }.get(self.intent, lambda: self.escalate("intencao_nao_identificada", "Mensagem do lojista sem intenção identificada pelas palavras-chave."))
        return handler()

    def call(self, name: str, tool_input: dict) -> dict:
        record = tools.call(name, tool_input, self.stamp)
        self.calls.append(record)
        return record["output"]

    def build(self, action_type: str, fields: dict) -> Decision:
        return Decision(action_type, fields, list(self.calls), self.intent, dict(self.entities))

    def reply(self, key: str, **values) -> Decision:
        return self.build("reply", {"text": REPLIES[self.locale][key].format(**values)})

    def thanks(self) -> Decision:
        return self.build("resolve", {"reason": RESOLVE_REASON})

    def transaction(self) -> Decision:
        transaction_id = self.entities.get("id_transacao")
        if transaction_id is None:
            return self.reply("pedir_transacao")
        output = self.call("consultar_transacao", {"id_transacao": transaction_id})
        status = output["status"]
        if status in ("aprovada", "estornada"):
            return self.reply(status, id=transaction_id, valor=money(output["valor"], self.locale),
                              data=day(output["data"], self.locale))
        if status == "contestada":
            return self.escalate("transacao_contestada",
                                 f"Lojista pergunta sobre a transação {transaction_id}; a consulta retornou a transação contestada.")
        return self.escalate("transacao_nao_localizada",
                             f"Lojista pergunta sobre a transação {transaction_id}; a consulta não encontrou a transação.")

    def payout(self) -> Decision:
        payout_date = self.entities.get("data")
        output = self.call("consultar_repasse", {"data": payout_date} if payout_date else {})
        status = output["status"]
        if status == "pago":
            return self.reply("pago", valor=money(output["valor"], self.locale),
                              data=day(output["data_pagamento"], self.locale))
        if status == "agendado":
            return self.reply("agendado", valor=money(output["valor"], self.locale),
                              data=day(output["previsao"], self.locale))
        period = f" de {payout_date}" if payout_date else ""
        return self.escalate("repasse_nao_localizado",
                             f"Lojista relata problema no repasse{period}; a consulta não encontrou o repasse.")

    def fees(self) -> Decision:
        output = self.call("consultar_taxas", {"marca": self.brand})
        return self.reply("taxas", **{name: percent(value, self.locale) for name, value in output.items()})

    def reader(self) -> Decision:
        serial = self.entities.get("numero_serie")
        if serial is None:
            return self.reply("pedir_serie")
        output = self.call("status_maquininha", {"numero_serie": serial})
        if output["status"] in ("online", "offline"):
            return self.reply(output["status"], serie=serial)
        return self.escalate("maquininha_com_defeito",
                             f"Lojista relata problema na maquininha {serial}; a consulta indica defeito.")

    def attempts(self) -> list[str]:
        if not self.calls:
            return ["Classificação da mensagem por palavras-chave sem ferramenta aplicável"]
        return [
            f"{call['name']} com entrada {tools.canonical(call['input'])}: {call['output']['status']}"
            if "status" in call["output"] else f"{call['name']} com entrada {tools.canonical(call['input'])}"
            for call in self.calls
        ]

    def escalate(self, reason: str, summary: str) -> Decision:
        next_step, confidence = ESCALATIONS[reason]
        context = {
            "intent": self.intent,
            "entities": dict(self.entities),
            "tools": [{"name": call["name"], "output": call["output"]} for call in self.calls],
            "attempts": self.attempts(),
            "sentiment": sentiment(self.text, self.locale),
            "suggested_next_step": next_step,
            "confidence": confidence,
        }
        return self.build("escalate", {"reason": reason, "summary": summary, "context": context})

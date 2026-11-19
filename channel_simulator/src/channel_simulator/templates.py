"""Conteúdo sintético das mensagens: modelos fixos por intenção e locale, e anexos.

Os campos dos modelos (id de transação, valor, data e número de série da maquininha) vêm do
random.Random da execução: a mesma semente gera a mesma sequência de textos. Nenhum dado é real.

Anexos: image (comprovante.jpg) e document (extrato.pdf). O e-mail leva os bytes gerados; o
WhatsApp e o chat levam só os metadados.
"""

import random
from dataclasses import dataclass
from datetime import date, timedelta

INTENTS = ("transacao", "repasse", "taxas", "maquininha", "saudacao")

TEMPLATES = {
    "pt-BR": {
        "transacao": [
            "Olá, a transação {transaction_id} de R$ {amount} do dia {date} não aparece no meu extrato.",
            "Fiz uma venda de R$ {amount} em {date} (id {transaction_id}) e o cliente diz que foi cobrado duas vezes.",
            "Podem verificar a transação {transaction_id}? Ela ficou pendente desde {date}.",
        ],
        "repasse": [
            "Meu repasse de {date} no valor de R$ {amount} ainda não caiu.",
            "Quando cai o repasse das vendas de {date}? São R$ {amount}.",
            "O repasse de R$ {amount} previsto para {date} veio com valor diferente.",
        ],
        "taxas": [
            "Qual a taxa do crédito parcelado em 12x?",
            "Fui cobrado R$ {amount} de taxa na venda {transaction_id}, está certo?",
            "Quero entender as taxas do débito e do Pix na minha conta.",
        ],
        "maquininha": [
            "Minha maquininha {serial} não liga desde {date}.",
            "A maquininha {serial} mostra erro de conexão ao passar o cartão.",
            "Preciso trocar a maquininha {serial}, a bateria não segura carga.",
        ],
        "saudacao": [
            "Oi, tudo bem? Preciso de ajuda.",
            "Bom dia! Alguém pode me atender?",
            "Olá, quero falar com o suporte.",
        ],
    },
    "en-US": {
        "transacao": [
            "Hi, transaction {transaction_id} for ${amount} on {date} is missing from my statement.",
            "I made a ${amount} sale on {date} (id {transaction_id}) and the customer says they were charged twice.",
            "Can you check transaction {transaction_id}? It has been pending since {date}.",
        ],
        "repasse": [
            "My payout from {date} for ${amount} has not arrived yet.",
            "When will the payout for my {date} sales arrive? It is ${amount}.",
            "The ${amount} payout expected on {date} came with a different amount.",
        ],
        "taxas": [
            "What is the fee for credit card installments?",
            "I was charged a ${amount} fee on sale {transaction_id}, is that right?",
            "I want to understand the debit and instant payment fees on my account.",
        ],
        "maquininha": [
            "My card reader {serial} has not turned on since {date}.",
            "Card reader {serial} shows a connection error when I swipe a card.",
            "I need to replace card reader {serial}, the battery does not hold a charge.",
        ],
        "saudacao": [
            "Hi, how are you? I need some help.",
            "Good morning! Can someone help me?",
            "Hello, I want to talk to support.",
        ],
    },
}

SUBJECTS = {
    "pt-BR": {
        "transacao": "Dúvida sobre transação",
        "repasse": "Repasse não recebido",
        "taxas": "Dúvida sobre taxas",
        "maquininha": "Problema na maquininha",
        "saudacao": "Atendimento",
    },
    "en-US": {
        "transacao": "Question about a transaction",
        "repasse": "Payout not received",
        "taxas": "Question about fees",
        "maquininha": "Card reader issue",
        "saudacao": "Support request",
    },
}

ATTACHMENT_KINDS = ("image", "document")

# Data de referência das datas sintéticas; fixa para que a semente defina o texto inteiro.
REFERENCE_DATE = date(2026, 11, 1)


@dataclass(frozen=True)
class Attachment:
    kind: str
    filename: str
    content_type: str
    data: bytes

    @property
    def size(self) -> int:
        return len(self.data)

    def metadata(self) -> dict:
        return {"kind": self.kind, "filename": self.filename, "content_type": self.content_type, "size": self.size}


@dataclass(frozen=True)
class Content:
    intent: str
    text: str
    subject: str
    attachment: Attachment | None


def _amount(rng: random.Random, locale: str) -> str:
    value = rng.randrange(1_000, 500_000) / 100
    if locale == "pt-BR":
        return f"{value:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return f"{value:,.2f}"


def _date(rng: random.Random, locale: str) -> str:
    day = REFERENCE_DATE - timedelta(days=rng.randrange(0, 30))
    return day.strftime("%d/%m/%Y") if locale == "pt-BR" else day.strftime("%m/%d/%Y")


def attachment(kind: str, rng: random.Random) -> Attachment:
    """Anexo sintético com bytes gerados por rng."""
    noise = rng.randbytes(256)
    if kind == "image":
        return Attachment("image", "comprovante.jpg", "image/jpeg", b"\xff\xd8\xff\xe0" + noise + b"\xff\xd9")
    if kind == "document":
        body = b"%PDF-1.4\n% simulador de canais do Cloudesk\n" + noise.hex().encode() + b"\n%%EOF\n"
        return Attachment("document", "extrato.pdf", "application/pdf", body)
    raise ValueError(f"tipo de anexo desconhecido: {kind}")


def generate(rng: random.Random, locale: str, intent: str | None = None, attachment_ratio: float = 0.0) -> Content:
    """Conteúdo de uma mensagem. Sem intent, a intenção é sorteada."""
    intent = intent or rng.choice(INTENTS)
    template = rng.choice(TEMPLATES[locale][intent])
    text = template.format(
        transaction_id=f"TX{rng.randrange(10**9, 10**10)}",
        amount=_amount(rng, locale),
        date=_date(rng, locale),
        serial=f"SN{rng.randrange(10**7, 10**8)}",
    )
    with_attachment = rng.random() < attachment_ratio
    kind = rng.choice(ATTACHMENT_KINDS) if with_attachment else None

    return Content(
        intent=intent,
        text=text,
        subject=SUBJECTS[locale][intent],
        attachment=attachment(kind, rng) if kind else None,
    )

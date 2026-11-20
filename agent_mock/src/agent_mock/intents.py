"""Intenção da mensagem por palavras-chave, por locale.

O texto é normalizado (caixa baixa, sem acentos) e dividido em palavras. Cada expressão casa só
com palavras inteiras. Em cada trecho do texto conta só a expressão mais longa que começa ali; cada
casamento soma 1 ponto à intenção da expressão. Vence a maior pontuação; o empate fica com a
intenção que vem primeiro em INTENTS. Sem nenhum casamento, a intenção é desconhecida.
"""

import re
import unicodedata

INTENTS = ("agradecimento", "transacao", "repasse", "taxas", "maquininha", "saudacao")
UNKNOWN = "desconhecida"

KEYWORDS = {
    "pt-BR": {
        "agradecimento": [
            "obrigado", "obrigada", "muito obrigado", "muito obrigada", "valeu", "agradeco", "grato", "grata",
        ],
        "transacao": [
            "transacao", "transacoes", "cobrado duas vezes", "cobrada duas vezes", "cobranca duplicada",
            "extrato", "pendente", "estorno",
        ],
        "repasse": ["repasse", "repasses", "recebimento", "antecipacao"],
        "taxas": ["taxa", "taxas", "tarifa", "tarifas", "mdr"],
        "maquininha": ["maquininha", "maquina de cartao", "leitor de cartao", "maquineta"],
        "saudacao": [
            "oi", "ola", "bom dia", "boa tarde", "boa noite", "tudo bem", "ajuda", "atender", "atendimento",
            "suporte",
        ],
    },
    "en-US": {
        "agradecimento": ["thanks", "thank you", "thank you so much", "appreciate it", "thx"],
        "transacao": [
            "transaction", "transactions", "charged twice", "double charge", "statement", "pending", "refund",
        ],
        "repasse": ["payout", "payouts", "settlement", "deposit"],
        "taxas": ["fee", "fees", "rate", "rates"],
        "maquininha": ["card reader", "card machine", "terminal", "pos device"],
        "saudacao": [
            "hi", "hello", "hey", "good morning", "good afternoon", "good evening", "how are you", "help",
            "support",
        ],
    },
}


def normalize(text: str) -> str:
    """Caixa baixa e sem acentos."""
    decomposed = unicodedata.normalize("NFKD", text.lower())
    return "".join(char for char in decomposed if not unicodedata.combining(char))


def words(text: str) -> list[str]:
    """Palavras do texto normalizado."""
    return re.findall(r"[a-z0-9]+", normalize(text))


def _expressions(keywords: dict[str, list[str]]) -> list[tuple[tuple[str, ...], str]]:
    """Expressões em palavras, da mais longa para a mais curta; empate pela ordem de INTENTS."""
    expressions = [
        (tuple(words(expression)), intent)
        for intent in INTENTS
        for expression in keywords.get(intent, [])
    ]
    return sorted(expressions, key=lambda item: -len(item[0]))


EXPRESSIONS = {locale: _expressions(keywords) for locale, keywords in KEYWORDS.items()}


def matches(tokens: list[str], expressions: list[tuple[tuple[str, ...], str]]) -> list[tuple[str, ...]]:
    """Expressões encontradas, só a mais longa de cada trecho, na ordem do texto."""
    found = []
    position = 0
    while position < len(tokens):
        for expression, _intent in expressions:
            if tuple(tokens[position:position + len(expression)]) == expression:
                found.append(expression)
                position += len(expression)
                break
        else:
            position += 1
    return found


def scores(text: str, locale: str) -> dict[str, int]:
    """Pontuação de cada intenção no texto."""
    expressions = EXPRESSIONS[locale]
    intent_of = {expression: intent for expression, intent in reversed(expressions)}
    result = {intent: 0 for intent in INTENTS}
    for expression in matches(words(text), expressions):
        result[intent_of[expression]] += 1
    return result


def classify(text: str, locale: str) -> str:
    """Intenção do texto no locale, ou desconhecida."""
    result = scores(text, locale)
    best = max(INTENTS, key=lambda intent: (result[intent], -INTENTS.index(intent)))
    return best if result[best] > 0 else UNKNOWN

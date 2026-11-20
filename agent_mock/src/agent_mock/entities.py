"""Entidades da mensagem, por expressão regular.

| Chave | Formato no texto | Valor |
| - | - | - |
| id_transacao | TX seguido de 10 dígitos | o próprio id, em maiúsculas |
| numero_serie | SN seguido de 8 dígitos | o próprio número, em maiúsculas |
| data | dd/mm/aaaa em pt-BR, mm/dd/yyyy em en-US | data ISO (aaaa-mm-dd) |
| valor | R$ 1.532,40 em pt-BR, $1,532.40 em en-US | decimal com ponto (1532.40) |

Vale a primeira ocorrência de cada entidade; data inexistente no calendário é ignorada.
"""

import re
from datetime import date

TRANSACTION = re.compile(r"\bTX\d{10}\b", re.IGNORECASE)
SERIAL = re.compile(r"\bSN\d{8}\b", re.IGNORECASE)
DATE = re.compile(r"\b(\d{2})/(\d{2})/(\d{4})\b")
AMOUNT = {
    "pt-BR": re.compile(r"R\$\s?(\d{1,3}(?:\.\d{3})*|\d+),(\d{2})\b"),
    "en-US": re.compile(r"\$\s?(\d{1,3}(?:,\d{3})*|\d+)\.(\d{2})\b"),
}


def _date(text: str, locale: str) -> str | None:
    for first, second, year in DATE.findall(text):
        day, month = (first, second) if locale == "pt-BR" else (second, first)
        try:
            return date(int(year), int(month), int(day)).isoformat()
        except ValueError:
            continue
    return None


def _amount(text: str, locale: str) -> str | None:
    match = AMOUNT[locale].search(text)
    if match is None:
        return None
    integer = re.sub(r"[.,]", "", match[1])
    return f"{int(integer)}.{match[2]}"


def extract(text: str, locale: str) -> dict[str, str]:
    """Entidades encontradas no texto, só as presentes."""
    found = {}
    if transaction := TRANSACTION.search(text):
        found["id_transacao"] = transaction[0].upper()
    if serial := SERIAL.search(text):
        found["numero_serie"] = serial[0].upper()
    if day := _date(text, locale):
        found["data"] = day
    if amount := _amount(text, locale):
        found["valor"] = amount
    return found

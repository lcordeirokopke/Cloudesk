"""Ferramentas falsas do agente: funções puras, sem banco.

O retorno de cada ferramenta vem do SHA-256 da entrada canônica (JSON com chaves ordenadas, com o
nome da ferramenta): a mesma entrada gera sempre o mesmo retorno. A entrada não leva ids de
conversa nem de contato, então a mesma mensagem gera o mesmo retorno em qualquer conversa.

| Ferramenta | Entrada | Status (faixa do hash) |
| - | - | - |
| consultar_transacao | id_transacao | aprovada 60%, estornada 15%, contestada 15%, nao_encontrada 10% |
| consultar_repasse | data, quando houver | pago 50%, agendado 30%, nao_encontrado 20% |
| consultar_taxas | marca | tabela fixa por marca |
| status_maquininha | numero_serie | online 50%, offline 30%, defeito 20% |

Valores e datas sintéticos também saem do hash; as datas contam a partir de REFERENCE_DATE, fixa.
"""

import hashlib
import json
from collections.abc import Callable
from datetime import date, timedelta

from agent_mock import clock

REFERENCE_DATE = date(2026, 11, 1)

TRANSACTION_STATUS = (("aprovada", 60), ("estornada", 15), ("contestada", 15), ("nao_encontrada", 10))
PAYOUT_STATUS = (("pago", 50), ("agendado", 30), ("nao_encontrado", 20))
READER_STATUS = (("online", 50), ("offline", 30), ("defeito", 20))

# Taxas sintéticas, em percentual.
FEES = {
    "infinitepay": {"debito": "1.37", "credito_a_vista": "3.15", "credito_12x": "12.40", "pix": "0.00"},
    "jim": {"debito": "1.50", "credito_a_vista": "2.90", "credito_12x": "11.90", "pix": "0.00"},
}
DEFAULT_FEES = {"debito": "1.99", "credito_a_vista": "3.49", "credito_12x": "13.90", "pix": "0.00"}


def canonical(value) -> str:
    """JSON com chaves ordenadas e sem espaços."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def digest(name: str, tool_input: dict) -> bytes:
    return hashlib.sha256(canonical({"ferramenta": name, "entrada": tool_input}).encode("utf-8")).digest()


def _number(hashed: bytes, start: int, modulo: int) -> int:
    return int.from_bytes(hashed[start:start + 4], "big") % modulo


def _status(hashed: bytes, table: tuple[tuple[str, int], ...]) -> str:
    bucket = _number(hashed, 0, 100)
    limit = 0
    for status, share in table:
        limit += share
        if bucket < limit:
            return status
    raise ValueError("faixas somam menos de 100")


def _amount(hashed: bytes) -> str:
    cents = 1_000 + _number(hashed, 4, 499_000)
    return f"{cents // 100}.{cents % 100:02d}"


def _day(hashed: bytes, base: date, days: int, forward: bool = False) -> str:
    offset = timedelta(days=_number(hashed, 8, days))
    return (base + offset if forward else base - offset).isoformat()


def consultar_transacao(tool_input: dict) -> dict:
    hashed = digest("consultar_transacao", tool_input)
    status = _status(hashed, TRANSACTION_STATUS)
    if status == "nao_encontrada":
        return {"status": status}
    return {"status": status, "valor": _amount(hashed), "data": _day(hashed, REFERENCE_DATE, 30)}


def consultar_repasse(tool_input: dict) -> dict:
    hashed = digest("consultar_repasse", tool_input)
    status = _status(hashed, PAYOUT_STATUS)
    base = date.fromisoformat(tool_input["data"]) if "data" in tool_input else REFERENCE_DATE
    if status == "pago":
        return {"status": status, "valor": _amount(hashed), "data_pagamento": base.isoformat()}
    if status == "agendado":
        return {"status": status, "valor": _amount(hashed), "previsao": _day(hashed, base + timedelta(days=1), 3, True)}
    return {"status": status}


def consultar_taxas(tool_input: dict) -> dict:
    return dict(FEES.get(tool_input["marca"], DEFAULT_FEES))


def status_maquininha(tool_input: dict) -> dict:
    hashed = digest("status_maquininha", tool_input)
    return {"status": _status(hashed, READER_STATUS)}


TOOLS: dict[str, Callable[[dict], dict]] = {
    "consultar_transacao": consultar_transacao,
    "consultar_repasse": consultar_repasse,
    "consultar_taxas": consultar_taxas,
    "status_maquininha": status_maquininha,
}


def call(name: str, tool_input: dict, stamp: Callable[[], str] = clock.stamp) -> dict:
    """Executa a ferramenta e devolve o registro do schema action: name, input, output e horários."""
    started_at = stamp()
    output = TOOLS[name](tool_input)
    finished_at = stamp()
    return {"name": name, "input": tool_input, "output": output, "started_at": started_at, "finished_at": finished_at}

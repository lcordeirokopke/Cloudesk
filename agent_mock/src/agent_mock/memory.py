"""Uso da memória do lojista (customer_memory do contexto) na decisão.

A conversa anterior relacionada é a mais recente de customer_memory.conversations cuja categoria
equivale à intenção atual e cujo resolved_at fica entre o received_at do evento menos a janela
(AGENT_MEMORY_WINDOW_DAYS) e o received_at, com os dois limites incluídos. A referência é o horário
do evento, não o relógio do processo: o mesmo evento com o mesmo contexto dá sempre o mesmo
resultado.

| Intenção | Categorias do Core |
| - | - |
| transacao | transacao, transaction |
| repasse | repasse, payout |
| taxas | taxas, fees |
| maquininha | maquininha, card_reader |
"""

from datetime import datetime, timedelta, timezone

CATEGORIES = {
    "transacao": ("transacao", "transaction"),
    "repasse": ("repasse", "payout"),
    "taxas": ("taxas", "fees"),
    "maquininha": ("maquininha", "card_reader"),
}


def parse_time(value: str) -> datetime:
    """Horário no formato do contrato (UTC com milissegundos)."""
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)


def previous(context: dict, intent: str, received_at: str, window_days: int) -> dict | None:
    """Conversa anterior relacionada à intenção, dentro da janela, ou None."""
    categories = CATEGORIES.get(intent)
    memory = context.get("customer_memory")
    if categories is None or not isinstance(memory, dict):
        return None

    reference = parse_time(received_at)
    start = reference - timedelta(days=window_days)
    candidates = [
        (parse_time(item["resolved_at"]), item)
        for item in memory.get("conversations", [])
        if item.get("category") in categories and isinstance(item.get("resolved_at"), str)
    ]
    inside = [(moment, item) for moment, item in candidates if start <= moment <= reference]
    if not inside:
        return None
    return max(inside, key=lambda pair: pair[0])[1]

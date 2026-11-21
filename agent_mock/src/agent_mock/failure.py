"""Escolha determinística dos eventos afetados pelo modo de falha (AGENT_FAILURE_MODE).

Os primeiros 8 dígitos hexadecimais do SHA-256 do event_id, lidos como inteiro e divididos por
2**32, dão um número em [0, 1). O evento é afetado quando esse número é menor que
AGENT_FAILURE_RATE: com taxa 1, todos; com taxa 0, nenhum. O mesmo evento reentregue tem sempre a
mesma escolha.
"""

import hashlib


def fraction(event_id: str) -> float:
    return int(hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:8], 16) / 2**32


def affected(event_id: str, rate: float) -> bool:
    return fraction(event_id) < rate

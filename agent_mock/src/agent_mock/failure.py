"""Escolha determinística dos eventos afetados pelo modo de falha.

Marcador no texto (marker): [falha:drop], [falha:duplicate], [falha:stale], [falha:delay] e
[falha:delay=<ms>], em minúsculas, em qualquer ponto do texto decidido. O evento com marcador é
sempre afetado, com o modo do marcador, sem consultar AGENT_FAILURE_MODE nem AGENT_FAILURE_RATE.
Com mais de um marcador, vale o primeiro. Todos os marcadores válidos saem do texto antes da
decisão, com os espaços repetidos reduzidos a um e as pontas aparadas. =<ms> só vale com delay:
[falha:drop=10], [FALHA:drop] e outros textos entre colchetes não são marcador e ficam no texto.

Sem marcador, vale a configuração (affected): os primeiros 8 dígitos hexadecimais do SHA-256 do
event_id, lidos como inteiro e divididos por 2**32, dão um número em [0, 1). O evento é afetado
pelo AGENT_FAILURE_MODE quando esse número é menor que AGENT_FAILURE_RATE: com taxa 1, todos; com
taxa 0, nenhum. O mesmo evento reentregue tem sempre a mesma escolha.
"""

import hashlib
import re
from dataclasses import dataclass

MARKER = re.compile(r"\[falha:(drop|duplicate|stale|delay)(?:=(\d+))?\]")
SPACES = re.compile(r"\s+")


@dataclass(frozen=True)
class Marker:
    mode: str
    delay_ms: int | None = None


def fraction(event_id: str) -> float:
    return int(hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:8], 16) / 2**32


def affected(event_id: str, rate: float) -> bool:
    return fraction(event_id) < rate


def _valid(match: re.Match) -> bool:
    return match[2] is None or match[1] == "delay"


def marker(text: str) -> tuple[Marker | None, str]:
    """Primeiro marcador válido do texto, ou None, e o texto sem os marcadores válidos."""
    found = None
    for match in MARKER.finditer(text):
        if _valid(match):
            found = Marker(match[1], int(match[2]) if match[2] is not None else None)
            break
    if found is None:
        return None, text

    cleaned = MARKER.sub(lambda match: " " if _valid(match) else match[0], text)
    return found, SPACES.sub(" ", cleaned).strip()

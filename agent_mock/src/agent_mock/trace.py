"""Contexto de trace no formato traceparent do W3C Trace Context: versão-trace_id-parent_id-flags.

Mesma regra de core/lib/trace_context.rb: o trace_id identifica o caminho inteiro de uma mensagem
e o parent_id identifica o salto que produziu o header. O agente mantém o trace_id do evento e gera
um parent_id próprio; sem header válido, inicia um trace.
"""

import re
import secrets
from dataclasses import dataclass, replace

VERSION = "00"
SAMPLED = "01"
PATTERN = re.compile(r"\A00-(?P<trace_id>[0-9a-f]{32})-(?P<parent_id>[0-9a-f]{16})-(?P<flags>[0-9a-f]{2})\Z")
INVALID_TRACE_ID = "0" * 32
INVALID_PARENT_ID = "0" * 16


@dataclass(frozen=True)
class Traceparent:
    trace_id: str
    parent_id: str
    flags: str

    def child(self) -> "Traceparent":
        """Mesmo trace, com o parent_id do salto corrente."""
        return replace(self, parent_id=secrets.token_hex(8))

    def __str__(self) -> str:
        return f"{VERSION}-{self.trace_id}-{self.parent_id}-{self.flags}"


def parse(header: str | bytes | None) -> Traceparent | None:
    """Traceparent do header, ou None quando o header falta ou é inválido.

    Só a versão 00 é aceita; trace_id e parent_id zerados são inválidos.
    """
    if isinstance(header, bytes):
        header = header.decode("utf-8", errors="replace")
    match = PATTERN.match((header or "").strip())
    if match is None:
        return None
    if match["trace_id"] == INVALID_TRACE_ID or match["parent_id"] == INVALID_PARENT_ID:
        return None
    return Traceparent(match["trace_id"], match["parent_id"], match["flags"])


def generate() -> Traceparent:
    """Inicia um trace."""
    return Traceparent(secrets.token_hex(16), secrets.token_hex(8), SAMPLED)


def continue_trace(header: str | bytes | None) -> Traceparent:
    """Continua o trace do header com um parent_id próprio; sem header válido, inicia um trace."""
    parent = parse(header)
    return parent.child() if parent else generate()

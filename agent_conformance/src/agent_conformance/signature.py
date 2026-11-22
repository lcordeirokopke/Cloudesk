"""Conferência da assinatura do contrato: HMAC-SHA256 com timestamp.

O texto assinado é "<timestamp>.<MÉTODO>.<caminho>.<corpo>": o timestamp é o horário Unix em
segundos, o caminho inclui a query string e o corpo é o texto bruto da requisição, vazio no GET.
Headers X-Cloudesk-Timestamp e X-Cloudesk-Signature, janela de 300 s. A regra é conferida com os
vetores de contracts/v1/signature-vectors.json.
"""

import hashlib
import hmac
import time

TIMESTAMP_HEADER = "X-Cloudesk-Timestamp"
SIGNATURE_HEADER = "X-Cloudesk-Signature"
TOLERANCE_SECONDS = 300


def sign(secret: str, timestamp: str, method: str, path: str, body: str = "") -> str:
    """Assinatura em hexadecimal."""
    if not secret:
        raise ValueError("segredo não informado")
    payload = f"{timestamp}.{method.upper()}.{path}.{body}".encode("utf-8")
    return hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()


def problem(secret: str, headers, method: str, path: str, body: str = "", now: float | None = None) -> str | None:
    """Motivo da recusa da assinatura, ou None quando ela confere."""
    timestamp = headers.get(TIMESTAMP_HEADER)
    received = headers.get(SIGNATURE_HEADER)
    if not timestamp or not received:
        return "headers de assinatura ausentes"
    if not timestamp.isdigit():
        return "timestamp inválido"
    current = time.time() if now is None else now
    if abs(current - int(timestamp)) > TOLERANCE_SECONDS:
        return "timestamp fora da janela de 300 s"
    if not hmac.compare_digest(sign(secret, timestamp, method, path, body), received):
        return "assinatura não confere"
    return None

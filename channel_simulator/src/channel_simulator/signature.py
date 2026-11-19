"""Assinatura HMAC-SHA256 com timestamp, a do contrato de integração. Cópia de
agent_mock/src/agent_mock/signature.py; o simulador usa na entrada JSON do chat.

O texto assinado é "<timestamp>.<MÉTODO>.<caminho>.<corpo>": o timestamp é o horário Unix em
segundos, o caminho inclui a query string e o corpo é o texto bruto da requisição, vazio no GET.
A implementação em Ruby fica em core/lib/contract/signature.rb; as duas são conferidas com os
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


def headers(secret: str, method: str, path: str, body: str = "", now: float | None = None) -> dict[str, str]:
    """Headers de uma chamada assinada no horário now (segundos Unix)."""
    timestamp = str(int(time.time() if now is None else now))
    return {
        TIMESTAMP_HEADER: timestamp,
        SIGNATURE_HEADER: sign(secret, timestamp, method, path, body),
    }

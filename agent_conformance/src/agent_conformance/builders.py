"""Eventos, headers e contextos válidos pelos schemas webhook.message-created,
kafka.inbound-headers e context, com conversation_id, event_id e trace novos a cada chamada.
"""

import secrets
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime

BRAND = "infinitepay"


def now() -> str:
    """Horário corrente no formato do contrato: UTC com milissegundos."""
    moment = datetime.now(UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def from_millis(milliseconds: int) -> str:
    moment = datetime.fromtimestamp(milliseconds / 1000, UTC)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.") + f"{moment.microsecond // 1000:03d}Z"


def new_id() -> str:
    return str(uuid.uuid4())


def new_traceparent() -> str:
    return f"00-{secrets.token_hex(16)}-{secrets.token_hex(8)}-01"


def trace_id(traceparent: str) -> str:
    return traceparent.split("-")[1]


@dataclass(frozen=True)
class Delivery:
    """Evento com os headers Kafka e o carimbo do Broker."""

    event: dict
    headers: dict[str, str]

    @property
    def conversation_id(self) -> str:
        return self.event["conversation_id"]


def delivery(text: str, *, sequence: int = 1, brand: str = BRAND, channel: str = "whatsapp",
             conversation_id: str | None = None) -> Delivery:
    conversation_id = conversation_id or new_id()
    traceparent = new_traceparent()
    received_at = now()
    event = {
        "event_id": new_id(),
        "type": "message.created",
        "brand": brand,
        "conversation_id": conversation_id,
        "sequence": sequence,
        "received_at": received_at,
        "message": {"author": "customer", "channel": channel, "text": text},
        "context_url": f"/api/v1/agent/brands/{brand}/conversations/{conversation_id}/context",
        "traceparent": traceparent,
    }
    headers = {"brand": brand, "traceparent": traceparent, "broker_received_at": now()}
    return Delivery(event, headers)


def context(item: Delivery, *, state: str = "with_ai", extra_messages: list[dict] | None = None,
            customer_memory: dict | None = None) -> dict:
    """Contexto da conversa do evento: as mensagens anteriores, a do evento e as extras."""
    event = item.event
    channel = event["message"]["channel"]
    messages = []
    for sequence in range(1, event["sequence"]):
        author = "customer" if sequence % 2 == 1 else "ai"
        messages.append({"sequence": sequence, "author": author, "channel": channel,
                         "text": "Oi" if author == "customer" else "Olá! Como posso ajudar?",
                         "created_at": event["received_at"]})
    messages.append({"sequence": event["sequence"], "author": "customer", "channel": channel,
                     "text": event["message"]["text"], "created_at": event["received_at"]})
    messages.extend(extra_messages or [])
    return {
        "conversation": {
            "id": event["conversation_id"], "brand": event["brand"], "channel": channel, "state": state,
            "last_sequence": max(message["sequence"] for message in messages),
        },
        "messages": messages,
        "customer_memory": customer_memory,
    }

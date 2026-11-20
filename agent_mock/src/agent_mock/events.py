"""Leitura de um registro de agent.inbound.

O valor é o JSON do evento message.created (schema webhook.message-created). Os headers são os do
schema kafka.inbound-headers, gravados pelo Broker: brand, traceparent e broker_received_at. O
timestamp do registro é o horário de gravação no Kafka (o tópico usa LogAppendTime) e vira o
kafka_appended_at da ação.

Registro sem os campos ou headers exigidos lança InvalidEvent.
"""

import json
import re
from dataclasses import dataclass

from agent_mock import clock

UUID = re.compile(r"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
BRAND = re.compile(r"\A[a-z0-9][a-z0-9_-]*\Z")
TIMESTAMP = re.compile(r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\Z")
CONTEXT_URL = re.compile(
    r"\A/api/v1/agent/brands/[a-z0-9][a-z0-9_-]*/conversations/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/context\Z"
)


class InvalidEvent(ValueError):
    pass


@dataclass(frozen=True)
class Event:
    event_id: str
    brand: str
    conversation_id: str
    sequence: int
    text: str
    channel: str
    context_url: str
    traceparent: str | None
    broker_received_at: str
    kafka_appended_at: str


def header(record, name: str) -> str | None:
    """Último valor do header no registro, como texto."""
    value = None
    for key, raw in record.headers or ():
        if key == name:
            value = raw
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidEvent(message)


def parse(record) -> Event:
    """Evento do registro Kafka de agent.inbound."""
    try:
        body = json.loads(record.value)
    except (TypeError, ValueError) as error:
        raise InvalidEvent(f"valor não é JSON: {error}") from error
    _require(isinstance(body, dict), "valor não é objeto JSON")
    _require(body.get("type") == "message.created", "tipo diferente de message.created")

    event_id = body.get("event_id")
    conversation_id = body.get("conversation_id")
    brand = body.get("brand")
    sequence = body.get("sequence")
    message = body.get("message")
    context_url = body.get("context_url")

    _require(isinstance(event_id, str) and bool(UUID.match(event_id)), "event_id inválido")
    _require(isinstance(conversation_id, str) and bool(UUID.match(conversation_id)), "conversation_id inválido")
    _require(isinstance(brand, str) and bool(BRAND.match(brand)), "brand inválida")
    _require(isinstance(sequence, int) and not isinstance(sequence, bool) and sequence >= 1, "sequence inválida")
    _require(isinstance(message, dict) and isinstance(message.get("text"), str) and bool(message["text"]),
             "message sem text")
    _require(isinstance(context_url, str) and bool(CONTEXT_URL.match(context_url)), "context_url inválida")
    _require(f"/brands/{brand}/conversations/{conversation_id}/" in context_url,
             "context_url de outra marca ou conversa")

    header_brand = header(record, "brand")
    broker_received_at = header(record, "broker_received_at")
    _require(header_brand == brand, "header brand ausente ou diferente da marca do evento")
    _require(broker_received_at is not None and bool(TIMESTAMP.match(broker_received_at)),
             "header broker_received_at ausente ou inválido")
    _require(isinstance(record.timestamp, int) and record.timestamp > 0, "registro sem timestamp")

    return Event(
        event_id=event_id,
        brand=brand,
        conversation_id=conversation_id,
        sequence=sequence,
        text=message["text"],
        channel=str(message.get("channel", "")),
        context_url=context_url,
        traceparent=header(record, "traceparent"),
        broker_received_at=broker_received_at,
        kafka_appended_at=clock.from_millis(record.timestamp),
    )

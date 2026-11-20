"""Ação do schema action, valor da mensagem Kafka em agent.outbound.

O based_on_sequence é a sequence do evento. A Idempotency-Key que o Broker calcula é
<inbound_event_id>:<type>; como a decisão é determinística, a reentrega de um evento gera a mesma
chave e o Core deduplica.
"""

import json

from agent_mock.decision import Decision
from agent_mock.events import Event


def build(event: Event, decision: Decision, *, traceparent: str, consumed_at: str, published_at: str) -> dict:
    return {
        "type": decision.type,
        "inbound_event_id": event.event_id,
        "brand": event.brand,
        "conversation_id": event.conversation_id,
        "based_on_sequence": event.sequence,
        "tools": decision.tools,
        "timestamps": {
            "broker_received_at": event.broker_received_at,
            "kafka_appended_at": event.kafka_appended_at,
            "agent_consumed_at": consumed_at,
            "agent_published_at": published_at,
        },
        "traceparent": traceparent,
        **decision.fields,
    }


def idempotency_key(action: dict) -> str:
    return f"{action['inbound_event_id']}:{action['type']}"


def headers(action: dict) -> dict[str, str]:
    """Headers do schema kafka.outbound-headers."""
    return {"brand": action["brand"], "traceparent": action["traceparent"]}


def encode(action: dict) -> bytes:
    return json.dumps(action, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

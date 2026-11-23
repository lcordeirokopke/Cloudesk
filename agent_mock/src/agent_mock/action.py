"""Ação do schema action, valor da mensagem Kafka em agent.outbound.

O based_on_sequence é a sequence do evento. A Idempotency-Key que o Broker calcula é
<inbound_event_id>:<type>; como a decisão é determinística, a reentrega de um evento gera a mesma
chave e o Core deduplica.

O model identifica quem decidiu: name agent-mock, version do pacote e, em parameters,
artificial_latency_ms, a latência artificial aplicada antes da publicação (AGENT_LATENCY_MS mais o
atraso do modo delay, quando aplicado). O Core desconta esse valor da latência ponta a ponta.
"""

import importlib.metadata
import json

from agent_mock.decision import Decision
from agent_mock.events import Event


def build(event: Event, decision: Decision, *, traceparent: str, consumed_at: str, published_at: str,
          model: dict | None = None) -> dict:
    built = {
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
    if model is not None:
        built["model"] = model
    return built


def model(latency_ms: int) -> dict:
    """Campo model da ação, com a latência artificial aplicada em milissegundos."""
    return {"name": "agent-mock", "version": importlib.metadata.version("agent-mock"),
            "parameters": {"artificial_latency_ms": latency_ms}}


def idempotency_key(action: dict) -> str:
    return f"{action['inbound_event_id']}:{action['type']}"


def headers(action: dict) -> dict[str, str]:
    """Headers do schema kafka.outbound-headers."""
    return {"brand": action["brand"], "traceparent": action["traceparent"]}


def encode(action: dict) -> bytes:
    return json.dumps(action, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

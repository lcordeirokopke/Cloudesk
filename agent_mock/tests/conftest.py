"""Apoio dos testes: contrato, registros Kafka falsos e eventos de exemplo."""

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

REPOSITORY = Path(__file__).resolve().parents[2]
CONTRACTS = Path(os.environ.get("CONTRACTS_PATH", REPOSITORY / "contracts")) / "v1"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

EVENT_ID = "019a8f3e-5b7a-7c21-9d43-1f2e3a4b5c6d"
CONVERSATION_ID = "019a8f3d-11aa-7b02-8c55-0a1b2c3d4e5f"
TRACEPARENT = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
BROKER_RECEIVED_AT = "2026-11-13T14:02:11.530Z"
# 2026-11-13T14:02:11.541Z em milissegundos Unix.
KAFKA_TIMESTAMP = 1794578531541


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def schema_validator(name: str) -> Draft202012Validator:
    return Draft202012Validator(read_json(CONTRACTS / "schemas" / f"{name}.json"))


@dataclass
class Record:
    """Registro Kafka no formato do ConsumerRecord do aiokafka."""

    value: bytes
    headers: list = field(default_factory=list)
    key: bytes | None = None
    timestamp: int = KAFKA_TIMESTAMP
    timestamp_type: int = 1
    topic: str = "agent.inbound"
    partition: int = 0
    offset: int = 0


def event_body(text="Meu repasse de 12/11/2026 ainda não caiu.", sequence=7, brand="infinitepay",
               conversation_id=CONVERSATION_ID, event_id=EVENT_ID, channel="whatsapp") -> dict:
    return {
        "event_id": event_id,
        "type": "message.created",
        "brand": brand,
        "conversation_id": conversation_id,
        "sequence": sequence,
        "received_at": "2026-11-13T14:02:11.482Z",
        "message": {"author": "customer", "channel": channel, "text": text},
        "context_url": f"/api/v1/agent/brands/{brand}/conversations/{conversation_id}/context",
        "traceparent": TRACEPARENT,
    }


def record(body: dict | None = None, offset: int = 0, partition: int = 0, **changes) -> Record:
    body = body or event_body(**changes)
    headers = [
        ("brand", body["brand"].encode()),
        ("traceparent", TRACEPARENT.encode()),
        ("broker_received_at", BROKER_RECEIVED_AT.encode()),
    ]
    return Record(
        value=json.dumps(body).encode(), headers=headers, key=body["conversation_id"].encode(),
        offset=offset, partition=partition,
    )


def context_for(body: dict, state="with_ai", messages=None) -> dict:
    messages = messages if messages is not None else [
        {"sequence": body["sequence"], "author": "customer", "channel": body["message"]["channel"],
         "text": body["message"]["text"], "created_at": "2026-11-13T14:02:11.482Z"},
    ]
    return {
        "conversation": {
            "id": body["conversation_id"], "brand": body["brand"], "channel": body["message"]["channel"],
            "state": state, "last_sequence": max([m["sequence"] for m in messages], default=0),
        },
        "messages": messages,
        "customer_memory": None,
    }


def without_times(action: dict) -> dict:
    """Ação sem carimbos de horário e sem traceparent, para comparar decisões."""
    copy = json.loads(json.dumps(action))
    copy.pop("timestamps", None)
    copy.pop("traceparent", None)
    for call in copy.get("tools", []):
        call.pop("started_at", None)
        call.pop("finished_at", None)
    return copy


@pytest.fixture
def action_validator():
    return schema_validator("action")

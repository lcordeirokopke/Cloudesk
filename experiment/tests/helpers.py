"""Construtores de dados sintéticos dos testes."""

import json

import pandas as pd

from cloudesk_experiment import prometheus

BASE = pd.Timestamp("2026-12-01T10:00:00Z")


def at(seconds: float) -> str:
    return (BASE + pd.Timedelta(seconds=seconds)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def metric(rows: list[tuple]) -> pd.DataFrame:
    """rows: (timestamp, labels, value)."""
    frame = pd.DataFrame(
        [(float(timestamp), json.dumps(labels, sort_keys=True), float(value)) for timestamp, labels, value in rows],
        columns=prometheus.COLUMNS,
    )
    return prometheus.with_labels(frame)


def jobs_frame(times, queue="webhooks", state="ready", value=lambda time: 0.0) -> pd.DataFrame:
    return metric([(time, {"queue": queue, "state": state}, value(time)) for time in times])


def lag_frame(times, group="cloudesk-agent", value=lambda time: 0.0) -> pd.DataFrame:
    return metric([(time, {"redpanda_group": group}, value(time)) for time in times])


def sent_frame(*rows: dict) -> pd.DataFrame:
    defaults = {"status": 200, "step": 0, "channel": "whatsapp", "sent_at": at(0), "duration_ms": 20.0}
    return pd.DataFrame([{**defaults, **row} for row in rows])


def message(external_id: str, conversation: str = "c1", sequence: int = 1, received: float = 0.0, **extra) -> dict:
    return {
        "brand": "infinitepay", "message_id": f"m-{external_id}", "external_id": external_id, "channel": "whatsapp",
        "conversation_id": conversation, "sequence": sequence, "created_at": at(received), "conversation_state": "with_ai",
        "event_id": f"e-{external_id}", "trace_id": "t", "received_at": at(received), **extra,
    }


def action(external_id: str, conversation: str = "c1", sequence: int = 1, name: str = "agent.reply", **extra) -> dict:
    return {
        "brand": "infinitepay", "action": name, "type": "reply", "conversation_id": conversation,
        "inbound_event_id": f"e-{external_id}", "based_on_sequence": sequence, "idempotency_key": f"e-{external_id}:reply",
        "broker_received_at": at(0.05), "kafka_appended_at": at(0.1), "agent_consumed_at": at(0.12),
        "agent_published_at": at(0.35), "artificial_latency_ms": 200.0, "received_at": at(0.4), **extra,
    }


def delivery(message_id: str, conversation: str = "c1", sequence: int = 1, delivered: float = 0.5, **extra) -> dict:
    return {
        "brand": "infinitepay", "message_id": message_id, "author": "ai", "channel": "whatsapp",
        "conversation_id": conversation, "in_reply_to_sequence": sequence, "delivered_at": at(delivered), **extra,
    }


def event(conversation: str = "c1", name: str = "conversation.routed", created: float = 0.0, **extra) -> dict:
    return {
        "brand": "infinitepay", "action": name, "conversation_id": conversation, "target_id": conversation,
        "reason": None, "first_attendant": "ai", "queue": "ip-suporte-geral", "created_at": at(created), **extra,
    }


def received(core_message_id: str, at_seconds: float = 1.0, channel: str = "whatsapp") -> dict:
    return {"channel": channel, "core_message_id": core_message_id, "received_at": at(at_seconds)}


def table(name: str, *rows: dict) -> pd.DataFrame:
    """Tabela da exportação, com as colunas dela mesmo sem linhas."""
    from cloudesk_experiment import report

    return pd.DataFrame(list(rows), columns=report.EXPORT_COLUMNS[name])

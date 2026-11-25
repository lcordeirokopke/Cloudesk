"""H2 e H4: valores exatos de audit_events e por histograma do Prometheus.

H2 decide pelo histograma do broker-web: fração até 0,3 s, fronteira exata de bucket. O denominador é
o maior valor entre as observações e as mensagens da etapa no Core, então a mensagem que não chegou ao
Kafka conta como acima da meta. Conferência: kafka_appended_at menos received_at.

H4 decide pelo valor exato: delivered_at da primeira entrega da IA menos received_at da mensagem
respondida, menos a latência artificial. Universo: mensagens da etapa no Core que não são
agradecimento. A mensagem sem resposta própria e coberta por ação aceita de mensagem mais nova sai do
universo e é contada; a sem resposta e sem cobertura entra como infinita.
"""

import math

import numpy as np
import pandas as pd

from . import prometheus

H2_LIMIT_SECONDS = 0.3
H4_LIMIT_SECONDS = 1.0
QUANTILE = 0.95
ACCEPTED_ACTIONS = ("agent.reply", "agent.escalate", "agent.categorize", "agent.resolve")


def timestamps(values: pd.Series) -> pd.Series:
    return pd.to_datetime(values, utc=True, format="ISO8601")


def seconds_between(start: pd.Series, end: pd.Series) -> pd.Series:
    return (timestamps(end) - timestamps(start)).dt.total_seconds()


def percentile(values, quantile: float) -> float | None:
    """Percentil pelo posto mais próximo (aceita infinito); None sem valores."""
    ordered = np.sort(np.asarray(values, dtype=float))
    if len(ordered) == 0:
        return None
    return float(ordered[max(math.ceil(round(quantile * len(ordered), 9)) - 1, 0)])


def percentiles(values) -> dict:
    return {f"p{round(q * 100)}": percentile(values, q) for q in (0.5, 0.95, 0.99)}


def h2_histogram(bucket_frame: pd.DataFrame, start: float, end: float, core_messages: int) -> dict:
    totals = prometheus.buckets(bucket_frame, start, end)
    observed = totals.get(float("inf"), 0.0)
    within = totals.get(H2_LIMIT_SECONDS, 0.0)
    denominator = max(observed, core_messages)
    fraction = within / denominator if denominator else None
    return {
        "confirmed": fraction is not None and fraction >= QUANTILE,
        "fraction_within_limit": fraction,
        "limit_seconds": H2_LIMIT_SECONDS,
        "observed": observed,
        "core_messages": core_messages,
        "p95_histogram": prometheus.histogram_quantile(totals, QUANTILE),
    }


def h2_exact(messages: pd.DataFrame, actions: pd.DataFrame) -> dict:
    """Percentis de kafka_appended_at menos received_at, por inbound_event_id."""
    stamps = actions.dropna(subset=["kafka_appended_at"]).drop_duplicates("inbound_event_id")
    joined = messages.merge(stamps[["inbound_event_id", "kafka_appended_at"]], left_on="event_id",
                            right_on="inbound_event_id")
    if joined.empty:
        return {"count": 0, **percentiles([])}
    values = seconds_between(joined["received_at"], joined["kafka_appended_at"])
    return {"count": len(values), **percentiles(values)}


def covered_up_to(actions: pd.DataFrame) -> dict[str, int]:
    """Maior based_on_sequence de ação aceita, por conversa."""
    accepted = actions[actions["action"].isin(ACCEPTED_ACTIONS)]
    if accepted.empty:
        return {}
    return accepted.groupby("conversation_id")["based_on_sequence"].max().astype(int).to_dict()


def h4_exact(messages: pd.DataFrame, actions: pd.DataFrame, deliveries: pd.DataFrame, thanks: set[str]) -> dict:
    """messages: mensagens da etapa no Core; thanks: external_id dos agradecimentos."""
    questions = messages[~messages["external_id"].isin(thanks)].copy()
    answers = deliveries[deliveries["author"] == "ai"].dropna(subset=["in_reply_to_sequence"]).copy()
    answers["in_reply_to_sequence"] = answers["in_reply_to_sequence"].astype(int)
    answers["delivered"] = timestamps(answers["delivered_at"])
    first = answers.sort_values("delivered").drop_duplicates(["conversation_id", "in_reply_to_sequence"])
    questions = questions.merge(first[["conversation_id", "in_reply_to_sequence", "delivered"]], how="left",
                                left_on=["conversation_id", "sequence"],
                                right_on=["conversation_id", "in_reply_to_sequence"])

    replies = actions[actions["action"] == "agent.reply"].drop_duplicates("inbound_event_id")
    artificial = dict(zip(replies["inbound_event_id"], replies["artificial_latency_ms"].fillna(0)))
    raw = (questions["delivered"] - timestamps(questions["received_at"])).dt.total_seconds()
    discount = questions["event_id"].map(artificial).fillna(0).astype(float) / 1000.0
    latency = raw - discount

    coverage = covered_up_to(actions)
    answered = questions["delivered"].notna()
    newer = questions["conversation_id"].map(coverage).fillna(0).astype(int) > questions["sequence"]
    covered = ~answered & newer
    unanswered = ~answered & ~newer

    infinite = [math.inf] * int(unanswered.sum())
    values = list(latency[answered]) + infinite
    p95 = percentile(values, QUANTILE)
    return {
        "confirmed": p95 is not None and p95 < H4_LIMIT_SECONDS,
        "limit_seconds": H4_LIMIT_SECONDS,
        "universe": len(values),
        "answered": int(answered.sum()),
        "covered_by_newer": int(covered.sum()),
        "unanswered": int(unanswered.sum()),
        **percentiles(values),
        "raw_p95": percentile(list(raw[answered]) + infinite, QUANTILE),
    }


def h4_histogram(bucket_frame: pd.DataFrame, start: float, end: float) -> dict:
    totals = prometheus.buckets(bucket_frame, start, end)
    observed = totals.get(float("inf"), 0.0)
    return {
        "observed": observed,
        "fraction_within_limit": totals.get(H4_LIMIT_SECONDS, 0.0) / observed if observed else None,
        "p95_histogram": prometheus.histogram_quantile(totals, QUANTILE),
    }

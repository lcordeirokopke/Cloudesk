"""Captura das séries do Prometheus e leitura das séries gravadas.

Cada consulta de QUERIES vira um CSV com as colunas timestamp (segundos Unix), labels (JSON com
chaves ordenadas, sem __name__ e job) e value. A captura usa query_range com passo de 5 s, o
intervalo da coleta; o lag do Redpanda é coletado a cada 15 s e se repete entre as coletas.
"""

import json
import urllib.parse
import urllib.request
from pathlib import Path

import pandas as pd

STEP_SECONDS = 5
DROPPED_LABELS = ("__name__", "job")
COLUMNS = ["timestamp", "labels", "value"]

QUERIES = {
    "solid_queue_jobs": "cloudesk_solid_queue_jobs",
    "solid_queue_oldest_ready": "cloudesk_solid_queue_oldest_ready_age_seconds",
    "solid_queue_failed": "cloudesk_solid_queue_failed_jobs",
    "consumer_lag": 'redpanda_kafka_consumer_group_lag_sum{redpanda_group=~"cloudesk-agent|cloudesk-broker"}',
    "broker_latency_bucket": "cloudesk_broker_inbound_latency_seconds_bucket",
    "broker_webhooks": "cloudesk_broker_webhooks_total",
    "end_to_end_bucket": "cloudesk_end_to_end_latency_seconds_bucket",
    "end_to_end_raw_bucket": "cloudesk_end_to_end_raw_latency_seconds_bucket",
    "hop_bucket": "cloudesk_hop_latency_seconds_bucket",
    "collect_errors": "cloudesk_metrics_collect_errors_total",
    "postgres_tps": "sum(rate(pg_stat_database_xact_commit[30s]))",
    "postgres_connections": "sum(pg_stat_activity_count)",
}
BACKLOG_QUERIES = ("solid_queue_jobs", "consumer_lag")


def fetch(base_url: str, query: str, start: float, end: float, step: int = STEP_SECONDS) -> dict:
    parameters = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    with urllib.request.urlopen(f"{base_url}/api/v1/query_range?{parameters}", timeout=60) as response:
        return json.load(response)


def parse(payload: dict) -> pd.DataFrame:
    """Linhas (timestamp, labels, value) de uma resposta do query_range."""
    if payload.get("status") != "success":
        raise ValueError(f"resposta do Prometheus sem sucesso: {payload.get('error', payload)}")
    rows = []
    for series in payload["data"]["result"]:
        labels = {name: value for name, value in series["metric"].items() if name not in DROPPED_LABELS}
        text = json.dumps(labels, sort_keys=True, ensure_ascii=False)
        rows.extend((float(timestamp), text, float(value)) for timestamp, value in series["values"])
    return pd.DataFrame(rows, columns=COLUMNS)


def with_labels(frame: pd.DataFrame) -> pd.DataFrame:
    """A mesma tabela com uma coluna por label."""
    if frame.empty:
        return frame
    labels = pd.DataFrame([json.loads(text) for text in frame["labels"]], index=frame.index)
    return pd.concat([frame, labels], axis=1)


def capture(base_url: str, start: float, end: float, directory: Path, names=None) -> None:
    """Grava em directory um CSV por consulta (todas, ou só as de names)."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name in names or QUERIES:
        parse(fetch(base_url, QUERIES[name], start, end)).to_csv(directory / f"{name}.csv", index=False)


def load(directory: Path, name: str) -> pd.DataFrame:
    """Série gravada, com uma coluna por label; vazia quando o arquivo não existe ou não tem linhas."""
    path = Path(directory) / f"{name}.csv"
    return with_labels(pd.read_csv(path)) if path.exists() else pd.DataFrame(columns=COLUMNS)


def increase(frame: pd.DataFrame, start: float, end: float) -> dict[str, float]:
    """Aumento de cada contador (por labels) entre start e end.

    A base é a última amostra até start. A série que começa depois de start tem base 0, e a amostra
    menor que a anterior é um reinício do processo, que conta a partir de 0.
    """
    result = {}
    for labels, series in frame[frame["timestamp"] <= end].groupby("labels"):
        series = series.sort_values("timestamp")
        before = series[series["timestamp"] <= start]
        previous = before["value"].iloc[-1] if len(before) else 0.0
        total = 0.0
        for value in series.loc[series["timestamp"] > start, "value"]:
            total += value - previous if value >= previous else value
            previous = value
        result[labels] = float(total)
    return result


def buckets(frame: pd.DataFrame, start: float, end: float, **labels: str) -> dict[float, float]:
    """Aumento acumulado por le, somado entre as séries que têm os labels informados."""
    totals: dict[float, float] = {}
    if frame.empty:
        return totals
    for text, value in increase(frame, start, end).items():
        series = json.loads(text)
        if all(series.get(name) == expected for name, expected in labels.items()):
            bound = float(series["le"])
            totals[bound] = totals.get(bound, 0.0) + value
    return dict(sorted(totals.items()))


def histogram_quantile(totals: dict[float, float], quantile: float) -> float | None:
    """Quantil por interpolação linear no bucket, como no Prometheus; None sem observação.

    No último bucket (+Inf), devolve a maior fronteira finita.
    """
    if not totals or max(totals.values()) <= 0:
        return None
    bounds = sorted(totals)
    rank = quantile * totals[bounds[-1]]
    lower, below = 0.0, 0.0
    for bound in bounds:
        if totals[bound] >= rank:
            if bound == float("inf"):
                return lower
            inside = totals[bound] - below
            return bound if inside <= 0 else lower + (bound - lower) * (rank - below) / inside
        lower, below = bound, totals[bound]
    return lower

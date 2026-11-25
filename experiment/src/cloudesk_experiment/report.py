"""Resumo da etapa (<etapa>-<n>/summary.json) e da sessão (summary.json), com as figuras.

A etapa é válida quando 100% das conversas dela foram roteadas à IA, sem agent.escalate, sem erro de
coleta do metrics e sem espera do host (suspensão por inatividade do Windows) durante a carga. Etapa inválida ou interrompida por guarda não conta como medida. O veredito de H1,
H2 e H4 vem da última execução medida do degrau de 250 msg/s, e o de H3, da última execução medida da
etapa h3. H5, H6 e H7 aplicam os critérios de H1, H2 e H4 à última execução medida do degrau da média,
8 msg/s. A sessão lista todas as execuções.
"""

import json
import math
from pathlib import Path

import pandas as pd

from . import backlog, figures, latency, prometheus, reconcile

TARGET_RATE = 250
H3_STAGE = "h3"
EMAIL_STAGE = "email"
TARGET_STAGE = "meta"
AVERAGE_RATE = 8
AVERAGE_STAGE = "escada-8"
CAPACITY_STAGES = ("escada-8", "escada-24", "escada-80", "meta", "extra")
PROJECT_PREFIX = "cloudesk-experiment-"
THANKS_STEP = 4
HOPS = ("core_to_broker", "broker_to_kafka", "kafka_to_agent", "agent", "agent_to_core", "core_to_channel")

EXPORT_COLUMNS = {
    "customer_messages": ["brand", "message_id", "external_id", "channel", "conversation_id", "sequence", "created_at",
                          "conversation_state", "event_id", "trace_id", "received_at"],
    "actions": ["brand", "action", "type", "conversation_id", "inbound_event_id", "based_on_sequence",
                "idempotency_key", "broker_received_at", "kafka_appended_at", "agent_consumed_at",
                "agent_published_at", "artificial_latency_ms", "received_at"],
    "deliveries": ["brand", "message_id", "author", "channel", "conversation_id", "in_reply_to_sequence",
                   "delivered_at"],
    "events": ["brand", "action", "conversation_id", "target_id", "reason", "first_attendant", "queue", "created_at"],
}


# Leitura


def read_jsonl(path: Path) -> pd.DataFrame:
    """Registros do arquivo; a linha incompleta (arquivo em escrita) é ignorada."""
    rows = []
    if Path(path).exists():
        with Path(path).open(encoding="utf-8") as file:
            for line in file:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return pd.DataFrame(rows)


def read_sent(path: Path) -> pd.DataFrame:
    frame = read_jsonl(path)
    return frame if len(frame) else pd.DataFrame(columns=["external_id", "status", "sent_at", "step", "channel"])


def read_received(path: Path) -> pd.DataFrame:
    frame = read_jsonl(path)
    return frame if len(frame) else pd.DataFrame(columns=["core_message_id", "received_at", "channel"])


def read_export(directory: Path) -> dict[str, pd.DataFrame]:
    return {name: pd.read_csv(Path(directory) / f"{name}.csv", dtype={"external_id": str, "reason": str})
            for name in EXPORT_COLUMNS}


def read_json(path: Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path: Path, data: dict) -> None:
    Path(path).write_text(json.dumps(clean(data), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def clean(value):
    """Infinito vira o texto "inf" e NaN vira null: o JSON não tem os dois."""
    if isinstance(value, dict):
        return {key: clean(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [clean(item) for item in value]
    if hasattr(value, "item"):
        value = value.item()
    if isinstance(value, float) and math.isinf(value):
        return "inf"
    if isinstance(value, float) and math.isnan(value):
        return None
    return value


def number(value) -> float | None:
    return math.inf if value == "inf" else value


def epoch(text: str) -> float:
    return pd.Timestamp(text).timestamp()


# Etapa


def load_window(sent: pd.DataFrame, conditions: dict) -> tuple[float, float]:
    """Início (primeiro envio) e fim da carga (duração pedida, ou a parada antecipada)."""
    if sent.empty:
        raise ValueError("a etapa não tem envios em sent.jsonl")
    start = epoch(sent["sent_at"].min())
    if conditions.get("load_stopped_at"):
        return start, epoch(conditions["load_stopped_at"])
    return start, start + conditions["duration_seconds"]


def dropped_iterations(path: Path) -> int:
    if not Path(path).exists():
        return 0
    metric = read_json(path).get("metrics", {}).get("dropped_iterations", {})
    return int(metric.get("values", {}).get("count", 0))


def standby_seconds(events: list[dict] | None, start: float, end: float) -> float | None:
    """Segundos da carga com o host em espera; None quando o host não informa os eventos."""
    if events is None:
        return None
    total, entered = 0.0, None
    for item in [*sorted(events, key=lambda event: event["at"]), {"at": None, "event": "exit"}]:
        moment = math.inf if item["at"] is None else epoch(item["at"])
        if item["event"] == "enter":
            entered = moment if entered is None else entered
        elif entered is not None:
            total += max(min(moment, end) - max(entered, start), 0.0)
            entered = None
    return total


def validity(export: dict, conversations: set, errors: float, conditions: dict, failed_jobs: dict,
             standby: float | None = None) -> dict:
    routed = export["events"]
    routed = routed[(routed["action"] == "conversation.routed") & routed["conversation_id"].isin(conversations)]
    to_ai = routed[routed["first_attendant"] == "ai"]
    without_route = len(conversations - set(routed["conversation_id"]))
    escalations = int(((export["actions"]["action"] == "agent.escalate")
                       & export["actions"]["conversation_id"].isin(conversations)).sum())
    return {
        "valid": len(conversations) > 0 and len(to_ai) == len(routed) and without_route == 0 and escalations == 0
                 and errors == 0 and not standby,
        "conversations": len(conversations),
        "routed": len(routed),
        "routed_to_ai": len(to_ai),
        "without_route": without_route,
        "agent_escalate": escalations,
        "metrics_collect_errors": errors,
        "host_standby_seconds": standby,
        "dlq_messages": max(conditions.get("dlq_after", 0) - conditions.get("dlq_before", 0), 0),
        "failed_jobs_at_end": failed_jobs,
    }


def stats_frame(path: Path) -> pd.DataFrame:
    """Amostras do docker stats por serviço: timestamp, service, cpu (% de um núcleo) e mem_mib."""
    columns = ["timestamp", "service", "cpu", "mem_mib"]
    if not Path(path).exists():
        return pd.DataFrame(columns=columns)
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        parts = line.split(",")
        if len(parts) != 4 or parts[1].startswith("_"):
            continue
        timestamp, name, cpu, mem = parts
        rows.append((timestamp, service_of(name), float(cpu.rstrip("%") or 0), mebibytes(mem.split("/")[0].strip())))
    frame = pd.DataFrame(rows, columns=columns)
    return frame.groupby(["timestamp", "service"], as_index=False)[["cpu", "mem_mib"]].sum()


def service_of(name: str) -> str:
    if not name.startswith(PROJECT_PREFIX):
        return "outros projetos"
    base, _, replica = name.removeprefix(PROJECT_PREFIX).rpartition("-")
    return base if base and replica.isdigit() else name.removeprefix(PROJECT_PREFIX)


def mebibytes(text: str) -> float:
    for unit, factor in (("GiB", 1024), ("MiB", 1), ("KiB", 1 / 1024), ("B", 1 / 1024 / 1024)):
        if text.endswith(unit):
            return float(text.removesuffix(unit)) * factor
    raise ValueError(f"memória desconhecida no docker stats: {text!r}")


def bottleneck(stage_dir: Path, series: pd.DataFrame, start: float, end: float, capture_end: float) -> dict:
    prom = stage_dir / "raw" / "prom"
    hops = prometheus.load(prom, "hop_bucket")
    stats = stats_frame(stage_dir / "raw" / "docker-stats.csv")
    if len(stats):
        when = pd.to_datetime(stats["timestamp"], utc=True, format="ISO8601").map(pd.Timestamp.timestamp)
        stats = stats[(when >= start) & (when <= end)]
    services = {
        service: {"cpu_mean": rows["cpu"].mean(), "cpu_max": rows["cpu"].max(), "mem_mib_max": rows["mem_mib"].max()}
        for service, rows in stats.groupby("service")
    }
    total = stats.groupby("timestamp")["cpu"].sum()

    def gauge(name):
        frame = prometheus.load(prom, name)
        frame = frame[(frame["timestamp"] >= start) & (frame["timestamp"] <= end)] if len(frame) else frame
        return {"mean": frame["value"].mean(), "max": frame["value"].max()} if len(frame) else None

    return {
        "cpu_total_mean": total.mean() if len(total) else None,
        "cpu_total_max": total.max() if len(total) else None,
        "services": services,
        "hop_p95": {hop: prometheus.histogram_quantile(prometheus.buckets(hops, start, capture_end, hop=hop), 0.95)
                    for hop in HOPS},
        "queues": {name: {"mean": series[name].mean(), "max": series[name].max()}
                   for name in (*backlog.QUEUES, *backlog.GROUPS)},
        "postgres_tps": gauge("postgres_tps"),
        "postgres_connections": gauge("postgres_connections"),
    }


def failed_at_end(frame: pd.DataFrame) -> dict[str, int]:
    if frame.empty:
        return {}
    last = frame.sort_values("timestamp").drop_duplicates("labels", keep="last")
    return {row["class"]: int(row["value"]) for _, row in last.iterrows() if row["value"] > 0}


def analyze_load(stage_dir: Path, conditions: dict) -> dict:
    raw, prom = stage_dir / "raw", stage_dir / "raw" / "prom"
    sent = read_sent(raw / "sent.jsonl")
    start, end = load_window(sent, conditions)
    capture_end = epoch(conditions["captured_until"])
    export = read_export(raw / "export")
    received = read_received(raw / "received.jsonl")
    messages = export["customer_messages"]
    messages = messages[messages["external_id"].isin(set(sent["external_id"]))]
    conversations = set(messages["conversation_id"])
    actions = export["actions"][export["actions"]["conversation_id"].isin(conversations)]
    thanks = set(sent.loc[sent["step"] == THANKS_STEP, "external_id"])
    jobs, lag = prometheus.load(prom, "solid_queue_jobs"), prometheus.load(prom, "consumer_lag")
    errors = sum(prometheus.increase(prometheus.load(prom, "collect_errors"), start, capture_end).values()) \
        if len(prometheus.load(prom, "collect_errors")) else 0.0

    checks = validity(export, conversations, errors, conditions, failed_at_end(prometheus.load(prom, "solid_queue_failed")),
                      standby_seconds(conditions.get("host_standby"), start, end))
    series = backlog.series(jobs, lag, start, capture_end)
    loaded = series[series["timestamp"] <= end]
    measured = conditions["status"] != "interrompida" and checks["valid"]
    try:
        h1 = backlog.h1(jobs, lag, sent, conditions["rate"], start, end, capture_end,
                        dropped_iterations(raw / "k6-summary.json"))
    except ValueError as error:
        h1 = {"sustained": False, "error": str(error)}

    summary = {
        "kind": "carga", "run": conditions["run"], "stage": conditions["stage"], "session": conditions["session"],
        "rate": conditions["rate"], "duration_seconds": end - start, "planned_duration_seconds": conditions["duration_seconds"],
        "status": conditions["status"], "reason": conditions.get("reason"), "measured": measured,
        "drained": conditions["drained"], "replicas": conditions["replicas"], "load_started_at": utc(start),
        "validity": checks,
        "h1": h1,
        "h1_sustained": h1["sustained"],
        "h2": {"histogram": latency.h2_histogram(prometheus.load(prom, "broker_latency_bucket"), start, capture_end, len(messages)),
               "exact": latency.h2_exact(messages, actions)},
        "h4": {"exact": latency.h4_exact(messages, actions, export["deliveries"], thanks),
               "histogram": latency.h4_histogram(prometheus.load(prom, "end_to_end_bucket"), start, capture_end)},
        "reconciliation": reconcile.summary(sent, messages, actions, export["events"], export["deliveries"], received,
                                            pd.Timestamp(start, unit="s", tz="UTC")),
        "http_req_duration_ms": latency.percentiles(sent.loc[sent["status"] == 200, "duration_ms"]),
        "bottleneck": bottleneck(stage_dir, loaded, start, end, capture_end),
    }
    faults = []
    if (stage_dir / "faults.json").exists():
        faults = read_json(stage_dir / "faults.json")["faults"]
        summary["faults"] = faults
    if (stage_dir / "robustness.json").exists():
        summary["robustness_check"] = read_json(stage_dir / "robustness.json")

    write_stage_figures(stage_dir, summary, series, start, end, faults)
    return summary


def analyze_email(stage_dir: Path, conditions: dict) -> dict:
    raw = stage_dir / "raw"
    sent = read_sent(raw / "sent.jsonl")
    start = epoch(sent["sent_at"].min())
    export = read_export(raw / "export")
    messages = export["customer_messages"]
    messages = messages[messages["external_id"].isin(set(sent["external_id"]))]
    conversations = set(messages["conversation_id"])
    actions = export["actions"][export["actions"]["conversation_id"].isin(conversations)]
    result = reconcile.summary(sent, messages, actions, export["events"], export["deliveries"],
                               read_received(raw / "received.jsonl"), pd.Timestamp(start, unit="s", tz="UTC"),
                               accepted_status=250, human_queue=True)
    to_agent = result["categories"]["atendida"] + result["categories"]["sem_acao"] + result["categories"]["ai_timeout"]
    summary = {
        "kind": "email", "run": conditions["run"], "stage": conditions["stage"], "session": conditions["session"],
        "status": conditions["status"], "reason": conditions.get("reason"), "load_started_at": utc(start),
        "messages_in_core": len(messages), "sent_to_agent": to_agent, "reconciliation": result,
        "deliveries": int(export["deliveries"]["conversation_id"].isin(conversations).sum()),
        "measured": conditions["status"] != "interrompida",
    }
    if (stage_dir / "robustness.json").exists():
        summary["robustness_check"] = read_json(stage_dir / "robustness.json")
    return summary


def analyze(stage_dir: Path) -> dict:
    stage_dir = Path(stage_dir)
    conditions = read_json(stage_dir / "conditions.json")
    summary = (analyze_email if conditions.get("kind") == "email" else analyze_load)(stage_dir, conditions)
    write_json(stage_dir / "summary.json", summary)
    return summary


def utc(seconds: float) -> str:
    return pd.Timestamp(seconds, unit="s", tz="UTC").isoformat(timespec="milliseconds").replace("+00:00", "Z")


def write_stage_figures(stage_dir: Path, summary: dict, series: pd.DataFrame, start: float, end: float, faults: list) -> None:
    name = f"{summary['run']}, {summary['rate']:g} msg/s"
    marks = [(epoch(fault["at"]) - start, fault["label"]) for fault in faults]
    if end < series["timestamp"].max():
        marks.append((end - start, "fim da carga"))
    hops = summary["bottleneck"]["hop_p95"]
    services = sorted(summary["bottleneck"]["services"].items(), key=lambda item: -item[1]["cpu_mean"])
    # A fila humana é categoria só do e-mail.
    categories = {key: value for key, value in summary["reconciliation"]["categories"].items() if key != "fila_humana"}
    charts = {
        "backlog": figures.backlog_figure(series, "Backlog e lag ao longo da etapa", name, marks),
        "hops": figures.bars(list(HOPS), [hops[hop] for hop in HOPS], "p95 por salto", name, figures.seconds_label),
        "reconciliation": figures.bars(list(categories), list(categories.values()), "Mensagens por categoria da reconciliação",
                                       name, lambda value: f"{value:,}".replace(",", ".")),
    }
    if services:
        charts["cpu"] = figures.bars([service for service, _ in services], [item["cpu_mean"] for _, item in services],
                                     "CPU média por serviço", f"{name}; 100% é um núcleo", lambda value: f"{value:.0f}%")
    figures.write(charts, stage_dir / "figures")


# Sessão


def stage_summaries(session_dir: Path) -> list[dict]:
    found = [read_json(path) for path in Path(session_dir).glob("*/summary.json")]
    return sorted(found, key=lambda item: item["load_started_at"])


def verdict(confirmed: bool | None) -> str:
    return "sem_medida" if confirmed is None else "confirmada" if confirmed else "refutada"


def degree(item: dict) -> dict:
    """Linha da tabela de execuções de carga."""
    return {
        "run": item["run"], "rate": item["rate"], "status": item["status"], "reason": item["reason"],
        "measured": item["measured"], "valid": item["validity"]["valid"], "replicas": item["replicas"],
        "duration_seconds": item["duration_seconds"], "drained": item["drained"],
        "h1_sustained": item["h1_sustained"], "h1": item["h1"],
        "h2_confirmed": item["h2"]["histogram"]["confirmed"],
        "h2_fraction_within_300ms": item["h2"]["histogram"]["fraction_within_limit"],
        "h2_p95": number(item["h2"]["exact"]["p95"]),
        "h4_confirmed": item["h4"]["exact"]["confirmed"], "h4_p95": number(item["h4"]["exact"]["p95"]),
        "h4_covered_by_newer": item["h4"]["exact"]["covered_by_newer"], "h4_universe": item["h4"]["exact"]["universe"],
        "lost": item["reconciliation"]["lost"], "duplicated": item["reconciliation"]["duplicated"],
        "refused": item["reconciliation"]["categories"]["recusada"],
        "hop_p95": item["bottleneck"]["hop_p95"], "cpu_total_mean": item["bottleneck"]["cpu_total_mean"],
    }


def capacity(rows: list[dict]) -> dict:
    """Faixa entre a maior taxa sustentada e a menor não sustentada, pelos degraus medidos."""
    measured = [row for row in rows if row["measured"] and row["run"].rpartition("-")[0] in CAPACITY_STAGES]
    sustained = [row["rate"] for row in measured if row["h1_sustained"]]
    failed = [row["rate"] for row in measured if not row["h1_sustained"]]
    return {"sustained_up_to": max(sustained, default=None), "not_sustained_from": min(failed, default=None)}


def h3_result(items: list[dict]) -> dict:
    runs = [item for item in items if item["kind"] == "carga" and item["stage"] == H3_STAGE]
    measured = [item for item in runs if item["measured"] and "robustness_check" in item]
    result = {"verdict": "sem_medida", "runs": [{
        "run": item["run"], "rate": item["rate"], "measured": item["measured"], "faults": item.get("faults", []),
        "reconciliation": item["reconciliation"], "robustness_exit_code": item.get("robustness_check", {}).get("exit_code"),
    } for item in runs]}
    if measured:
        last = measured[-1]
        result["verdict"] = verdict(last["reconciliation"]["ok"] and last["robustness_check"]["exit_code"] == 0)
        result["run"] = last["run"]
    return result


def session_summary(items: list[dict]) -> dict:
    loads = [item for item in items if item["kind"] == "carga"]
    rows = [degree(item) for item in loads]
    targets = [row for row, item in zip(rows, loads) if item["stage"] == TARGET_STAGE]
    measured = [row for row in targets if row["measured"]]
    last = measured[-1] if measured else None

    def target_verdict(key):
        return verdict(last[key] if last else None)

    averages = [row for row, item in zip(rows, loads) if item["stage"] == AVERAGE_STAGE and row["measured"]]
    average = averages[-1] if averages else None

    def average_verdict(key):
        return verdict(average[key] if average else None)

    steps = [row for row in rows if row["measured"]]
    return {
        "session": items[0]["session"] if items else None,
        "target_rate": TARGET_RATE,
        "hypotheses": {
            "H1": {"verdict": target_verdict("h1_sustained"), "run": last and last["run"], "criteria": last and last["h1"]},
            "H2": {"verdict": target_verdict("h2_confirmed"), "run": last and last["run"],
                   "fraction_within_300ms": last and last["h2_fraction_within_300ms"], "p95_seconds": last and last["h2_p95"],
                   "goal_met_at": sorted({row["rate"] for row in steps if row["h2_confirmed"]}),
                   "goal_not_met_at": sorted({row["rate"] for row in steps if not row["h2_confirmed"]})},
            "H3": h3_result(items),
            "H4": {"verdict": target_verdict("h4_confirmed"), "run": last and last["run"], "p95_seconds": last and last["h4_p95"],
                   "goal_met_at": sorted({row["rate"] for row in steps if row["h4_confirmed"]}),
                   "goal_not_met_at": sorted({row["rate"] for row in steps if not row["h4_confirmed"]})},
            "H5": {"verdict": average_verdict("h1_sustained"), "run": average and average["run"], "rate": AVERAGE_RATE,
                   "criteria": average and average["h1"]},
            "H6": {"verdict": average_verdict("h2_confirmed"), "run": average and average["run"], "rate": AVERAGE_RATE,
                   "fraction_within_300ms": average and average["h2_fraction_within_300ms"],
                   "p95_seconds": average and average["h2_p95"]},
            "H7": {"verdict": average_verdict("h4_confirmed"), "run": average and average["run"], "rate": AVERAGE_RATE,
                   "p95_seconds": average and average["h4_p95"]},
        },
        "capacity": capacity(rows),
        "target_runs": targets,
        "runs": rows,
        "email": [{key: item[key] for key in ("run", "messages_in_core", "sent_to_agent", "deliveries", "reconciliation")}
                  | {"robustness_exit_code": item.get("robustness_check", {}).get("exit_code")}
                  for item in items if item["kind"] == "email"],
    }


def report(session_dir: Path) -> dict:
    session_dir = Path(session_dir)
    summary = session_summary(stage_summaries(session_dir))
    write_json(session_dir / "summary.json", summary)
    steps = sorted((row for row in summary["runs"]
                    if row["measured"] and row["run"].rpartition("-")[0] in CAPACITY_STAGES), key=lambda row: row["rate"])
    charts = {}
    if any(row["h2_p95"] is not None for row in steps):
        charts["h2-p95-por-degrau"] = figures.p95_by_rate(
            steps, "h2_p95", latency.H2_LIMIT_SECONDS, "p95 entrada → Kafka por degrau", "kafka_appended_at menos received_at, escala log")
    if any(row["h4_p95"] is not None for row in steps):
        charts["h4-p95-por-degrau"] = figures.p95_by_rate(
            steps, "h4_p95", latency.H4_LIMIT_SECONDS, "p95 ponta a ponta por degrau", "descontada a latência artificial do agente, escala log")
    figures.write(charts, session_dir / "figures")
    return summary


def rounds_table(items: list[dict]) -> str:
    """Tabela em texto das execuções de carga, para a escolha da configuração."""
    lines = [f"{'execução':<14}{'msg/s':>6}{'medida':>8}{'H1':>5}{'incl/s':>9}{'aceita':>8}{'zera s':>8}{'H2 p95':>10}{'H4 p95':>12}{'CPU':>8}  réplicas"]
    for row in (degree(item) for item in items if item["kind"] == "carga"):
        a, b, c = (row["h1"].get(key, {}) for key in ("a_backlog_slope", "b_acceptance", "c_zero_backlog"))
        zero = c.get("seconds")
        replicas = " ".join(f"{name}={count}" for name, count in row["replicas"].items())
        lines.append(
            f"{row['run']:<14}{row['rate']:>6g}{'sim' if row['measured'] else 'não':>8}{'sim' if row['h1_sustained'] else 'não':>5}"
            f"{a.get('slope_per_second', math.nan):>9.3f}{b.get('accepted_share', math.nan):>8.1%}"
            f"{'-' if zero is None else f'{zero:.0f}':>8}{figures.seconds_label(row['h2_p95']):>10}"
            f"{figures.seconds_label(row['h4_p95']):>12}{row['cpu_total_mean'] or math.nan:>7.0f}%  {replicas}"
        )
    return "\n".join(lines)

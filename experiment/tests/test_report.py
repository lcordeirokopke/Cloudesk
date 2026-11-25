import json

import pandas as pd
import pytest
from helpers import BASE, action, at, delivery, event, jobs_frame, lag_frame, message, metric, received, table

from cloudesk_experiment import cli, prometheus, report

REPLICAS = {"web": 4, "jobs-webhooks": 2}
START = BASE.timestamp()


def write_stage(session, run, rate, status="concluida", stage=None, growing=False, slow=False, reason=None, robustness=None,
                duration=300, started=0):
    """Etapa sintética com uma mensagem por segundo da taxa; devolve a pasta."""
    folder = session / run
    raw = folder / "raw"
    (raw / "export").mkdir(parents=True)
    (raw / "prom").mkdir()
    stage = stage or run.rpartition("-")[0]
    conditions = {
        "session": session.name, "stage": stage, "run": run, "kind": "carga", "rate": rate, "duration_seconds": duration,
        "status": status, "reason": reason, "drained": True, "replicas": REPLICAS, "dlq_before": 0, "dlq_after": 0,
        "captured_until": at(started + duration + 120),
    }
    (folder / "conditions.json").write_text(json.dumps(conditions), encoding="utf-8")

    total = int(rate * duration)
    names = [f"wamid.exp-{run}-{i}" for i in range(total)]
    with (raw / "sent.jsonl").open("w", encoding="utf-8") as file:
        for i, name in enumerate(names):
            file.write(json.dumps({"external_id": name, "status": 200, "step": 0, "channel": "whatsapp",
                                   "sent_at": at(started + i / rate), "duration_ms": 25.0}) + "\n")
        file.write('{"external_id": "incompleta')
    seconds = [started + i / rate for i in range(total)]
    delay = 4.0 if slow else 0.5
    table("customer_messages", *[message(n, f"c-{n}", received=s) for n, s in zip(names, seconds)]).to_csv(raw / "export" / "customer_messages.csv", index=False)
    table("actions", *[action(n, f"c-{n}", kafka_appended_at=at(s + 0.1)) for n, s in zip(names, seconds)]).to_csv(raw / "export" / "actions.csv", index=False)
    table("deliveries", *[delivery(f"r-{n}", f"c-{n}", delivered=s + delay) for n, s in zip(names, seconds)]).to_csv(raw / "export" / "deliveries.csv", index=False)
    table("events", *[event(f"c-{n}") for n in names]).to_csv(raw / "export" / "events.csv", index=False)
    with (raw / "received.jsonl").open("w", encoding="utf-8") as file:
        for n, s in zip(names, seconds):
            file.write(json.dumps(received(f"r-{n}", s + 1)) + "\n")

    times = [START + started + t for t in range(-60, duration + 125, 5)]
    load_end = START + started + duration
    depth = (lambda t: max(0, 5 * (t - START - started))) if growing else (lambda t: 12 + t % 7 if t < load_end else 0)
    (pd.concat([jobs_frame(times, value=depth)]))[prometheus.COLUMNS].to_csv(raw / "prom" / "solid_queue_jobs.csv", index=False)
    lag_frame(times)[prometheus.COLUMNS].to_csv(raw / "prom" / "consumer_lag.csv", index=False)
    rows = []
    for bound in ("0.2", "0.3", "+Inf"):
        labels = {"brand": "jim", "instance": "b1", "le": bound}
        rows += [(times[0], labels, 0), (times[-1], labels, total)]
    metric(rows)[prometheus.COLUMNS].to_csv(raw / "prom" / "broker_latency_bucket.csv", index=False)
    (raw / "docker-stats.csv").write_text(
        f"{at(started + 30)},cloudesk-experiment-web-1,120.5%,210MiB / 7.6GiB\n{at(started + 30)},cloudesk-experiment-web-2,80%,1.5GiB / 7.6GiB\n"
        f"{at(started + 30)},cloudesk-experiment-k6,30%,90MiB / 7.6GiB\n{at(started + 30)},outro,1%,10MiB / 7.6GiB\n"
        f"{at(started + 30)},_memavailable,,4000000\n", encoding="utf-8")
    if robustness is not None:
        (folder / "robustness.json").write_text(json.dumps({"exit_code": robustness, "output": ""}), encoding="utf-8")
        (folder / "faults.json").write_text(json.dumps({"faults": [{"at": at(started + 120), "label": "restart broker-web"}]}), encoding="utf-8")
    return folder


@pytest.fixture(autouse=True)
def no_figures(monkeypatch, request):
    """Grava só o nome das figuras, menos no teste que gera PNG."""
    written = []
    if "png" not in request.keywords:
        monkeypatch.setattr(report.figures, "write", lambda charts, directory: written.extend(charts))
    return written


def test_resumo_da_etapa(tmp_path):
    summary = report.analyze(write_stage(tmp_path / "s1", "escada-8-1", 8))

    assert summary["measured"] and summary["validity"]["valid"]
    assert summary["h1_sustained"]
    assert summary["h2"]["histogram"]["confirmed"]
    assert summary["h2"]["exact"]["p95"] == pytest.approx(0.1, abs=0.002)
    assert summary["h4"]["exact"]["p95"] == pytest.approx(0.3, abs=0.002)
    assert summary["reconciliation"]["ok"]
    services = summary["bottleneck"]["services"]
    assert services["web"]["cpu_mean"] == pytest.approx(200.5)
    assert services["web"]["mem_mib_max"] == pytest.approx(210 + 1536)
    assert set(services) == {"web", "k6", "outros projetos"}
    assert report.read_json(tmp_path / "s1" / "escada-8-1" / "summary.json")["run"] == "escada-8-1"


def test_etapa_com_roteamento_humano_ou_escalate_e_invalida(tmp_path):
    folder = write_stage(tmp_path / "s1", "escada-8-1", 8)
    events = pd.read_csv(folder / "raw" / "export" / "events.csv")
    events.loc[0, "first_attendant"] = "human"
    events.to_csv(folder / "raw" / "export" / "events.csv", index=False)

    summary = report.analyze(folder)

    assert not summary["validity"]["valid"]
    assert not summary["measured"]

    actions = pd.read_csv(folder / "raw" / "export" / "actions.csv")
    actions.loc[0, "action"] = "agent.escalate"
    actions.to_csv(folder / "raw" / "export" / "actions.csv", index=False)
    assert report.analyze(folder)["validity"]["agent_escalate"] == 1


def test_espera_do_host_dentro_da_carga_invalida_a_etapa(tmp_path):
    folder = write_stage(tmp_path / "s1", "piloto-1", 8)
    conditions = report.read_json(folder / "conditions.json")
    conditions["host_standby"] = [{"at": at(-600), "event": "enter"}, {"at": at(-500), "event": "exit"}]
    (folder / "conditions.json").write_text(json.dumps(conditions), encoding="utf-8")
    assert report.analyze(folder)["measured"]

    conditions["host_standby"].append({"at": at(240), "event": "enter"})
    (folder / "conditions.json").write_text(json.dumps(conditions), encoding="utf-8")
    summary = report.analyze(folder)
    assert summary["validity"]["host_standby_seconds"] == 60
    assert not summary["measured"]


def test_segundos_de_espera():
    enter, leave = (lambda second: {"at": at(second), "event": "enter"}), (lambda second: {"at": at(second), "event": "exit"})
    start = BASE.timestamp()

    assert report.standby_seconds(None, start, start + 100) is None
    assert report.standby_seconds([], start, start + 100) == 0
    assert report.standby_seconds([enter(-50), leave(10)], start, start + 100) == 10
    assert report.standby_seconds([enter(-50)], start, start + 100) == 100
    assert report.standby_seconds([leave(20), enter(200)], start, start + 100) == 0


def test_parada_antecipada_usa_a_duracao_ate_a_parada(tmp_path):
    folder = write_stage(tmp_path / "s1", "meta-1", 8)
    conditions = report.read_json(folder / "conditions.json") | {"status": "parada_h1", "load_stopped_at": at(150)}
    (folder / "conditions.json").write_text(json.dumps(conditions), encoding="utf-8")

    summary = report.analyze(folder)

    assert summary["duration_seconds"] == 150
    assert summary["h1"]["b_acceptance"]["planned"] == 1200
    assert summary["measured"]


def test_sessao_com_confirmada_refutada_e_interrompida(tmp_path):
    session = tmp_path / "s1"
    for arguments in (
        dict(run="escada-8-1", rate=8, started=0),
        dict(run="meta-1", rate=20, growing=True, slow=True, started=1000, reason="critério a"),
        dict(run="meta-2", rate=20, status="interrompida", started=2000, reason="memória"),
        dict(run="h3-1", rate=8, robustness=0, started=3000),
    ):
        report.analyze(write_stage(session, **arguments))

    summary = report.report(session)

    hypotheses = summary["hypotheses"]
    assert hypotheses["H1"]["verdict"] == "refutada"
    assert hypotheses["H1"]["run"] == "meta-1"
    assert hypotheses["H2"]["verdict"] == "confirmada"
    assert hypotheses["H4"]["verdict"] == "refutada"
    assert hypotheses["H4"]["goal_met_at"] == [8]
    assert hypotheses["H3"]["verdict"] == "confirmada"
    assert hypotheses["H3"]["runs"][0]["faults"][0]["label"] == "restart broker-web"
    assert [run["run"] for run in summary["target_runs"]] == ["meta-1", "meta-2"]
    assert [run["measured"] for run in summary["target_runs"]] == [True, False]
    assert summary["capacity"] == {"sustained_up_to": 8, "not_sustained_from": 20}
    assert report.read_json(session / "summary.json")["session"] == "s1"
    table_text = report.rounds_table(report.stage_summaries(session))
    assert "meta-2" in table_text and "web=4" in table_text


def test_h3_refutada_pela_robustness_check(tmp_path):
    report.analyze(write_stage(tmp_path / "s1", "h3-1", 8, robustness=1))

    assert report.report(tmp_path / "s1")["hypotheses"]["H3"]["verdict"] == "refutada"


def test_hipoteses_na_media_usam_a_ultima_execucao_medida_de_8(tmp_path):
    session = tmp_path / "s1"
    report.analyze(write_stage(session, "escada-8-1", 8))
    report.analyze(write_stage(session, "escada-8-2", 8, growing=True, slow=True, started=1000))
    report.analyze(write_stage(session, "escada-8-3", 8, status="interrompida", started=2000, reason="memória"))
    report.analyze(write_stage(session, "piloto-1", 8, started=3000))

    hypotheses = report.report(session)["hypotheses"]

    assert [hypotheses[name]["run"] for name in ("H5", "H6", "H7")] == ["escada-8-2"] * 3
    assert hypotheses["H5"]["verdict"] == "refutada"
    assert hypotheses["H7"]["verdict"] == "refutada"
    assert hypotheses["H6"]["verdict"] == "confirmada"
    assert hypotheses["H5"]["rate"] == 8


def test_sem_o_degrau_de_8_as_hipoteses_na_media_ficam_sem_medida(tmp_path):
    report.analyze(write_stage(tmp_path / "s1", "piloto-1", 8))

    hypotheses = report.report(tmp_path / "s1")["hypotheses"]
    assert [hypotheses[name]["verdict"] for name in ("H5", "H6", "H7")] == ["sem_medida"] * 3


def test_sem_execucao_de_250_fica_sem_medida(tmp_path):
    report.analyze(write_stage(tmp_path / "s1", "escada-8-1", 8))

    hypotheses = report.report(tmp_path / "s1")["hypotheses"]

    assert [hypotheses[name]["verdict"] for name in ("H1", "H2", "H3", "H4")] == ["sem_medida"] * 4


def test_h1_check_com_a_carga_em_andamento(tmp_path, monkeypatch):
    folder = write_stage(tmp_path / "s1", "meta-1", 8, growing=True)

    def capture(_url, _start, _end, directory, names):
        for name in names:
            (directory / f"{name}.csv").write_text((folder / "raw" / "prom" / f"{name}.csv").read_text(), encoding="utf-8")

    monkeypatch.setattr(prometheus, "capture", capture)

    assert cli.main(["h1-check", str(folder), "--rate", "8", "--until", "300"]) == cli.CHECK_FAILED
    result = report.read_json(folder / "h1-check.json")
    assert not result["a_backlog_slope"]["ok"]
    assert result["b_accepted_share"]["ok"]


def test_json_sem_infinito_nem_nan(tmp_path):
    report.write_json(tmp_path / "x.json", {"a": float("inf"), "b": [float("nan")], "c": 1.5})

    assert report.read_json(tmp_path / "x.json") == {"a": "inf", "b": [None], "c": 1.5}
    assert report.number("inf") == float("inf")


@pytest.mark.png
def test_png_da_etapa_e_da_sessao(tmp_path):
    folder = write_stage(tmp_path / "s1", "escada-8-1", 8, robustness=0)
    report.analyze(folder)
    report.report(tmp_path / "s1")

    generated = [*folder.glob("figures/*.png"), *(tmp_path / "s1" / "figures").glob("*.png")]

    assert {path.stem for path in generated} == {"backlog", "hops", "cpu", "reconciliation", "h2-p95-por-degrau",
                                                 "h4-p95-por-degrau"}
    assert all(path.read_bytes().startswith(b"\x89PNG") for path in generated)

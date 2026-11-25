"""Linha de comando da análise do experimento.

| Comando | Efeito |
| - | - |
| capture DIR --start --end | Grava em DIR/raw/prom as séries do Prometheus |
| h1-check DIR --until | Critérios (a) e (b) da H1 com a carga em andamento; código 0 passa, 3 reprova |
| analyze DIR | summary.json e figuras da etapa, a partir de DIR/raw |
| report DIR | summary.json e figuras da sessão |
| table DIR | Tabela das execuções da sessão |
"""

import argparse
import json
import math
import sys
import tempfile
from pathlib import Path

from . import backlog, prometheus, report

DEFAULT_PROMETHEUS = "http://prometheus:9090"
# Código do h1-check com critério reprovado; o código 1 é erro de execução.
CHECK_FAILED = 3


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cloudesk-experiment", description="Análise do experimento de carga do Cloudesk")
    parser.add_argument("--prometheus", default=DEFAULT_PROMETHEUS)
    commands = parser.add_subparsers(dest="command", required=True)

    capture = commands.add_parser("capture", help="grava as séries do Prometheus da etapa")
    capture.add_argument("directory", type=Path)
    capture.add_argument("--start", required=True, help="ISO 8601")
    capture.add_argument("--end", required=True, help="ISO 8601")

    check = commands.add_parser("h1-check", help="critérios (a) e (b) da H1 com a carga em andamento")
    check.add_argument("directory", type=Path)
    check.add_argument("--rate", type=float, required=True)
    check.add_argument("--until", type=float, required=True, help="segundos desde o primeiro envio")

    for name, text in (("analyze", "resumo e figuras da etapa"), ("report", "resumo e figuras da sessão"),
                       ("table", "tabela das execuções da sessão")):
        commands.add_parser(name, help=text).add_argument("directory", type=Path)
    return parser


def h1_check(base_url: str, directory: Path, rate: float, until: float) -> dict:
    """Critério (a), de 1 min até until, e (b), pela taxa aceita até until."""
    sent = report.read_sent(directory / "raw" / "sent.jsonl")
    start = report.epoch(sent["sent_at"].min())
    with tempfile.TemporaryDirectory() as folder:
        prometheus.capture(base_url, start - 60, start + until, Path(folder), prometheus.BACKLOG_QUERIES)
        jobs, lag = (prometheus.load(Path(folder), name) for name in prometheus.BACKLOG_QUERIES)
    moments = [report.epoch(text) - start for text in sent["sent_at"]]
    slope = backlog.slope(backlog.series(jobs, lag, start, start + until), rate, until)
    accepted = backlog.acceptance(sent[[moment < until for moment in moments]], rate, until)
    return {
        "passed": slope.ok and accepted.accepted_share >= backlog.MIN_ACCEPTED,
        "a_backlog_slope": {"ok": slope.ok, "slope_per_second": slope.slope, "upper_95": slope.upper, "limit": slope.limit},
        "b_accepted_share": {"ok": accepted.accepted_share >= backlog.MIN_ACCEPTED, "value": accepted.accepted_share},
        "until_seconds": until,
    }


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "capture":
        prometheus.capture(args.prometheus, report.epoch(args.start), report.epoch(args.end), args.directory / "raw" / "prom")
        return 0
    if args.command == "h1-check":
        result = h1_check(args.prometheus, args.directory, args.rate, args.until)
        report.write_json(args.directory / "h1-check.json", result)
        print(json.dumps(report.clean(result), ensure_ascii=False))
        return 0 if result["passed"] else CHECK_FAILED
    if args.command == "analyze":
        summary = report.analyze(args.directory)
        print(json.dumps(report.clean({key: value for key, value in summary.items() if key != "bottleneck"}),
                         ensure_ascii=False, indent=2))
        return 0
    if args.command == "report":
        summary = report.report(args.directory)
        print(json.dumps(report.clean({key: summary[key] for key in ("hypotheses", "capacity")}), ensure_ascii=False, indent=2))
        return 0
    print(report.rounds_table(report.stage_summaries(args.directory)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

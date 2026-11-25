import json
from pathlib import Path

import pytest
from helpers import metric

from cloudesk_experiment import prometheus

EXAMPLE = json.loads((Path(__file__).parent / "data" / "query_range.json").read_text(encoding="utf-8"))
EMPTY = {"status": "success", "data": {"resultType": "matrix", "result": []}}
COUNTER = {"instance": "a"}


def counter(*samples):
    return metric([(timestamp, COUNTER, value) for timestamp, value in samples])


def total(frame, start, end):
    return sum(prometheus.increase(frame, start, end).values())


def test_leitura_do_query_range():
    frame = prometheus.parse(EXAMPLE)

    assert list(frame.columns) == ["timestamp", "labels", "value"]
    assert list(frame["value"]) == [3, 7, 2]
    assert json.loads(frame["labels"][0]) == {"instance": "metrics:9394", "queue": "webhooks", "state": "ready"}


def test_resposta_de_erro():
    with pytest.raises(ValueError, match="bad_data"):
        prometheus.parse({"status": "error", "error": "bad_data"})


def test_captura_grava_um_csv_por_consulta(tmp_path, monkeypatch):
    calls = []

    def fetch(base_url, query, start, end):
        calls.append((base_url, query, start, end))
        return EXAMPLE if query == "cloudesk_solid_queue_jobs" else EMPTY

    monkeypatch.setattr(prometheus, "fetch", fetch)
    prometheus.capture("http://p", 1, 2, tmp_path)

    assert {path.stem for path in tmp_path.iterdir()} == set(prometheus.QUERIES)
    assert [query for _, query, _, _ in calls] == list(prometheus.QUERIES.values())
    loaded = prometheus.load(tmp_path, "solid_queue_jobs")
    assert list(loaded["queue"]) == ["webhooks", "webhooks", "channels"]
    assert prometheus.load(tmp_path, "consumer_lag").empty


def test_serie_ausente_e_vazia(tmp_path):
    frame = prometheus.load(tmp_path, "nao_existe")

    assert frame.empty
    assert prometheus.buckets(frame, 0, 1) == {}
    assert prometheus.histogram_quantile({}, 0.95) is None


def test_aumento_do_contador():
    assert total(counter((0, 10), (5, 12), (10, 20), (15, 99)), start=0, end=10) == 10


def test_contador_que_reinicia_conta_a_partir_de_zero():
    assert total(counter((0, 10), (5, 15), (10, 2), (15, 6)), start=0, end=15) == 11


def test_serie_que_comeca_depois_do_inicio_tem_base_zero():
    assert total(counter((10, 4), (15, 6)), start=5, end=15) == 6


def test_buckets_somam_instancias_e_filtram_por_label():
    rows = []
    for instance, hop in (("a", "agent"), ("b", "agent"), ("a", "core_to_broker")):
        for bound in ("0.3", "+Inf"):
            labels = {"instance": instance, "hop": hop, "le": bound}
            rows += [(0, labels, 0), (10, labels, 5 if bound == "0.3" else 8)]

    assert prometheus.buckets(metric(rows), 0, 10, hop="agent") == {0.3: 10, float("inf"): 16}


def test_quantil_por_interpolacao():
    totals = {0.1: 50, 0.2: 90, 0.3: 100, float("inf"): 100}

    assert prometheus.histogram_quantile(totals, 0.95) == pytest.approx(0.25)
    assert prometheus.histogram_quantile({0.1: 1, float("inf"): 100}, 0.95) == 0.1

import math

import pytest
from helpers import action, at, delivery, message, metric, table

from cloudesk_experiment import latency


def bucket_frame(within, total):
    labels = {"brand": "jim", "instance": "a"}
    rows = []
    for bound, value in (("0.2", within / 2), ("0.3", within), ("+Inf", total)):
        rows += [(0, {**labels, "le": bound}, 100), (10, {**labels, "le": bound}, 100 + value)]
    return metric(rows)


def h4(messages, actions, deliveries, thanks=()):
    return latency.h4_exact(table("customer_messages", *messages), table("actions", *actions),
                            table("deliveries", *deliveries), set(thanks))


def test_fracao_no_bucket_de_0_3():
    result = latency.h2_histogram(bucket_frame(95, 100), 5, 10, core_messages=100)

    assert result["fraction_within_limit"] == pytest.approx(0.95)
    assert result["confirmed"]
    assert not latency.h2_histogram(bucket_frame(94, 100), 5, 10, core_messages=100)["confirmed"]


def test_mensagem_fora_do_kafka_conta_no_denominador():
    result = latency.h2_histogram(bucket_frame(96, 96), 5, 10, core_messages=120)

    assert result["fraction_within_limit"] == pytest.approx(0.8)
    assert not result["confirmed"]


def test_reenvio_acima_das_mensagens_do_core_fica_no_denominador():
    assert latency.h2_histogram(bucket_frame(96, 120), 5, 10, 100)["fraction_within_limit"] == pytest.approx(0.8)


def test_sem_observacao_nao_confirma():
    result = latency.h2_histogram(metric([(0, {"le": "0.3"}, 0)]), 5, 10, 0)

    assert result["fraction_within_limit"] is None
    assert not result["confirmed"]


def test_h2_exato_usa_kafka_appended_at_menos_received_at():
    messages = table("customer_messages", message("a", received=0), message("b", "c2", received=0))
    actions = table("actions", action("a", kafka_appended_at=at(0.1)), action("b", "c2", kafka_appended_at=at(0.4)))

    result = latency.h2_exact(messages, actions)

    assert result["count"] == 2
    assert result["p50"] == pytest.approx(0.1)
    assert result["p95"] == pytest.approx(0.4)


def test_percentil_pelo_posto_mais_proximo_aceita_infinito():
    assert latency.percentile(range(1, 101), 0.95) == 95
    assert latency.percentile([1] * 94 + [math.inf] * 6, 0.95) == math.inf
    assert latency.percentile([], 0.95) is None


def test_h4_desconta_a_latencia_artificial():
    result = h4([message("a")], [action("a")], [delivery("r1", delivered=0.9)])

    assert result["p95"] == pytest.approx(0.7)
    assert result["raw_p95"] == pytest.approx(0.9)
    assert result["confirmed"]


def test_h4_conta_a_primeira_entrega():
    result = h4([message("a")], [action("a")], [delivery("r1", delivered=5), delivery("r1", delivered=0.5)])

    assert result["p95"] == pytest.approx(0.3)
    assert result["universe"] == 1


def test_h4_agradecimento_fora_do_universo():
    result = h4([message("a"), message("t", sequence=3)], [action("a"), action("t", sequence=3, name="agent.resolve")],
                [delivery("r1")], thanks=["t"])

    assert result["universe"] == 1
    assert result["unanswered"] == 0


def test_h4_coberta_por_acao_mais_nova_sai_do_universo():
    result = h4([message("a"), message("b", sequence=2)], [action("b", sequence=2)], [delivery("r1", sequence=2)])

    assert result["universe"] == 1
    assert result["covered_by_newer"] == 1
    assert result["unanswered"] == 0


def test_h4_sem_resposta_e_sem_cobertura_entra_como_infinita():
    result = h4([message("a"), message("b", "c2")], [action("a")], [delivery("r1")])

    assert result["unanswered"] == 1
    assert result["p95"] == math.inf
    assert not result["confirmed"]


def test_h4_acao_recusada_nao_cobre():
    result = h4([message("a"), message("b", sequence=2)], [action("b", sequence=2, name="agent.action.stale")], [])

    assert result["unanswered"] == 2


def test_h4_mensagem_do_sistema_nao_e_resposta():
    assert h4([message("a")], [], [delivery("r1", author="system")])["unanswered"] == 1


def test_h4_histograma():
    labels = {"channel": "chat"}
    rows = []
    for bound, value in (("0.5", 50), ("1", 90), ("2.5", 100), ("+Inf", 100)):
        rows += [(0, {**labels, "le": bound}, 0), (10, {**labels, "le": bound}, value)]

    result = latency.h4_histogram(metric(rows), 5, 10)

    assert result["fraction_within_limit"] == pytest.approx(0.9)
    assert result["p95_histogram"] == pytest.approx(1.75)

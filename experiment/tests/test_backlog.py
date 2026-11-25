import numpy as np
import pandas as pd
import pytest
from helpers import jobs_frame, lag_frame, metric, sent_frame

from cloudesk_experiment import backlog

RATE = 80
DURATION = 300
TIMES = range(0, 500, 5)


def noise(time):
    return 10 + (time * 7) % 11


def sent(accepted, total=None, rate=RATE, duration=DURATION):
    total = total or int(rate * duration)
    return sent_frame(*[{"external_id": str(i), "status": 200 if i < accepted else 503} for i in range(total)])


def test_serie_estavel_passa():
    frame = backlog.series(jobs_frame(TIMES, value=noise), lag_frame(TIMES), 0, DURATION)

    result = backlog.slope(frame, RATE, DURATION)

    assert result.ok
    assert result.limit == pytest.approx(0.8)
    assert result.samples == 17


def test_crescimento_reprova():
    frame = backlog.series(jobs_frame(TIMES, value=lambda time: noise(time) + 2 * time), lag_frame(TIMES), 0, DURATION)

    result = backlog.slope(frame, RATE, DURATION)

    assert not result.ok
    assert result.slope == pytest.approx(2, abs=0.1)


def test_crescimento_do_lag_tambem_reprova():
    frame = backlog.series(jobs_frame(TIMES), lag_frame(TIMES, value=lambda time: 3 * time), 0, DURATION)

    assert not backlog.slope(frame, RATE, DURATION).ok


def test_primeiro_minuto_descartado():
    frame = backlog.series(jobs_frame(TIMES, value=lambda time: 0 if time < 60 else 5000), lag_frame(TIMES), 0, DURATION)

    assert backlog.slope(frame, RATE, DURATION).ok


def test_backlog_constante_tem_inclinacao_zero():
    frame = backlog.series(jobs_frame(TIMES), lag_frame(TIMES), 0, DURATION)

    result = backlog.slope(frame, RATE, DURATION)

    assert (result.slope, result.upper) == (0, 0)
    assert result.ok


def test_poucas_amostras_e_erro():
    frame = backlog.series(jobs_frame(TIMES), lag_frame(TIMES), 0, 60)

    with pytest.raises(ValueError, match="1 amostra"):
        backlog.slope(frame, RATE, 60)


def test_serie_soma_filas_em_execucao_e_lag_e_ignora_agendados_e_outras_filas():
    labels = [({"queue": "webhooks", "state": "ready"}, 1), ({"queue": "webhooks", "state": "claimed"}, 2),
              ({"queue": "channels", "state": "ready"}, 4), ({"queue": "default", "state": "claimed"}, 8),
              ({"queue": "webhooks", "state": "scheduled"}, 100), ({"queue": "action_mailbox_routing", "state": "ready"}, 1000)]
    lag = pd.concat([lag_frame([0], "cloudesk-agent", lambda _: 16), lag_frame([0], "cloudesk-broker", lambda _: 32)])

    frame = backlog.series(metric([(0, label, value) for label, value in labels]), lag, 0, 0)

    assert frame.loc[0, "backlog"] == 63
    assert frame.loc[0, "jobs"] == 15
    assert frame.loc[0, "scheduled"] == 100


def test_amostra_usa_o_ultimo_valor_ate_o_instante():
    values = backlog.sample(lag_frame([10, 20], value=lambda time: time), np.array([5.0, 15.0, 40.0]))

    assert list(values) == [0, 10, 20]


def test_taxa_aceita_de_99_por_cento_passa_e_de_98_9_reprova():
    total = RATE * DURATION
    planned_only = sent(int(total * 0.99), int(total * 0.99))
    below = sent(int(total * 0.989), int(total * 0.989))

    assert backlog.acceptance(planned_only, RATE, DURATION).ok
    assert backlog.acceptance(below, RATE, DURATION).accepted_share == pytest.approx(0.989)
    assert not backlog.acceptance(below, RATE, DURATION).ok


def test_dropped_iterations_de_1_por_cento_reprova():
    total = RATE * DURATION

    assert not backlog.acceptance(sent(total), RATE, DURATION, dropped=int(total * 0.01)).ok


def test_falhas_de_1_por_cento_reprovam():
    total = RATE * DURATION

    assert not backlog.acceptance(sent(int(total * 0.99), total), RATE, DURATION).ok


def drained(value, queue="default", state="ready", until=120):
    return backlog.series(jobs_frame(range(0, until, 5), queue, state, value), lag_frame(range(0, until, 5)), 0, until - 5)


def test_zerado_com_5_jobs_e_nao_com_6():
    assert backlog.zero_after(drained(lambda _: 5)) == 0
    assert backlog.zero_after(drained(lambda _: 6)) is None


def test_agendado_de_webhooks_impede_o_zerado():
    assert backlog.zero_after(drained(lambda _: 1, "webhooks", "scheduled")) is None
    assert backlog.zero_after(drained(lambda _: 1, "default", "scheduled")) == 0


def test_lag_impede_o_zerado():
    frame = backlog.series(jobs_frame(range(0, 120, 5)), lag_frame(range(0, 120, 5), value=lambda _: 1), 0, 115)

    assert backlog.zero_after(frame) is None


def test_uma_amostra_zerada_so_nao_basta():
    frame = drained(lambda time: 0 if 25 <= time <= 30 else 50)

    assert backlog.zero_after(frame) is None


def test_limite_de_60_segundos():
    assert backlog.zero_after(drained(lambda time: 50 if time < 60 else 0)) == 60
    assert backlog.zero_ok(60)
    assert not backlog.zero_ok(75)
    assert not backlog.zero_ok(None)


def test_h1_junta_os_tres_criterios():
    times = range(0, 500, 5)
    result = backlog.h1(jobs_frame(times, value=lambda time: noise(time) if time <= DURATION else 0), lag_frame(times),
                        sent(RATE * DURATION), RATE, 0, DURATION, 480, 0)

    assert result["sustained"]
    assert result["c_zero_backlog"]["seconds"] == 15

    late = backlog.h1(jobs_frame(times, value=lambda time: noise(time) if time <= DURATION + 100 else 0), lag_frame(times),
                      sent(RATE * DURATION), RATE, 0, DURATION, 480, 0)
    assert not late["sustained"]
    assert late["a_backlog_slope"]["ok"] and late["b_acceptance"]["ok"]

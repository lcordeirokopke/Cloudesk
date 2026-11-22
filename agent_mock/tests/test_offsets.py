import asyncio

import pytest

from agent_mock.config import Settings, parse_locales
from agent_mock.runner import OffsetTracker, Scheduler


def test_confirma_so_o_offset_contiguo():
    tracker = OffsetTracker()
    for offset in (10, 11, 12):
        tracker.started("p0", offset)

    tracker.finished("p0", 10)

    assert tracker.commits() == {"p0": 11}


def test_lacuna_segura_a_confirmacao():
    tracker = OffsetTracker()
    for offset in (10, 11, 12):
        tracker.started("p0", offset)

    tracker.finished("p0", 11)
    tracker.finished("p0", 12)
    assert tracker.commits() == {}

    tracker.finished("p0", 10)
    assert tracker.commits() == {"p0": 13}


def test_offsets_nao_consecutivos_no_topico():
    tracker = OffsetTracker()
    for offset in (3, 7, 9):
        tracker.started("p0", offset)

    tracker.finished("p0", 3)
    tracker.finished("p0", 7)

    assert tracker.commits() == {"p0": 8}


def test_particoes_independentes():
    tracker = OffsetTracker()
    tracker.started("p0", 0)
    tracker.started("p1", 0)

    tracker.finished("p1", 0)

    assert tracker.commits() == {"p1": 1}


def test_nao_repete_confirmacao_registrada():
    tracker = OffsetTracker()
    tracker.started("p0", 0)
    tracker.finished("p0", 0)

    tracker.committed(tracker.commits())

    assert tracker.commits() == {}


def test_esquece_particao_revogada():
    tracker = OffsetTracker()
    tracker.started("p0", 0)
    tracker.forget("p0")

    tracker.finished("p0", 0)

    assert tracker.commits() == {}


async def test_em_serie_na_mesma_conversa_e_em_paralelo_entre_conversas():
    tracker = OffsetTracker()
    scheduler = Scheduler(10, tracker)
    events = []
    release = {key: asyncio.Event() for key in ("a1", "b1")}

    def work(name, gate=None):
        async def run():
            events.append(f"{name}:inicio")
            if gate:
                await release[gate].wait()
            events.append(f"{name}:fim")
        return run

    await scheduler.submit("p0", 0, b"a", work("a1", "a1"))
    await scheduler.submit("p0", 1, b"b", work("b1", "b1"))
    await scheduler.submit("p0", 2, b"a", work("a2"))
    await asyncio.sleep(0.01)

    assert events == ["a1:inicio", "b1:inicio"]

    release["b1"].set()
    await asyncio.sleep(0.01)
    assert "b1:fim" in events and "a2:inicio" not in events
    assert tracker.commits() == {}

    release["a1"].set()
    await scheduler.wait_partitions(["p0"])
    assert events.index("a1:fim") < events.index("a2:inicio")
    assert tracker.commits() == {"p0": 3}


async def test_semaforo_segura_a_leitura():
    scheduler = Scheduler(1, OffsetTracker())
    gate = asyncio.Event()

    async def slow():
        await gate.wait()

    await scheduler.submit("p0", 0, b"a", slow)
    second = asyncio.create_task(scheduler.submit("p0", 1, b"b", slow))
    await asyncio.sleep(0.01)
    assert not second.done()

    gate.set()
    await second
    await scheduler.wait_partitions(["p0"])


async def test_registro_recusado_depois_da_espera_nao_e_agendado():
    tracker = OffsetTracker()
    scheduler = Scheduler(1, tracker)

    async def noop():
        return None

    assert await scheduler.submit("p0", 0, b"a", noop, accept=lambda: False) is None
    assert scheduler.tasks() == set()
    assert scheduler.semaphore._value == 1


async def test_falha_inesperada_segura_o_offset_e_para():
    tracker = OffsetTracker()
    scheduler = Scheduler(5, tracker)

    async def broken():
        raise RuntimeError("defeito")

    await scheduler.submit("p0", 0, b"a", broken)
    await scheduler.wait_partitions(["p0"])

    assert isinstance(scheduler.failure, RuntimeError)
    assert tracker.commits() == {}


def test_configuracao_do_ambiente():
    settings = Settings.from_env({
        "KAFKA_BROKERS": "k:9092", "CORE_URL": "http://core/", "AGENT_CONTEXT_SECRET": "s",
        "AGENT_CONCURRENCY": "7", "AGENT_LATENCY_MS": "150", "AGENT_BRAND_LOCALES": "a:pt-BR, b:en-US",
    })

    assert settings.core_url == "http://core"
    assert settings.concurrency == 7
    assert settings.latency_ms == 150
    assert settings.group_id == "cloudesk-agent"
    assert settings.brand_locales == {"a": "pt-BR", "b": "en-US"}
    assert Settings.from_env({}).brand_locales == {"infinitepay": "pt-BR", "jim": "en-US"}


def test_locale_invalido():
    with pytest.raises(ValueError):
        parse_locales("a:fr-FR")


class StopRun(Exception):
    pass


async def test_runner_assina_e_publica_nos_topicos_de_settings(monkeypatch):
    from agent_mock import runner as runner_module

    subscribed, sent = [], []

    class FakeConsumer:
        def __init__(self, **_options):
            pass

        def subscribe(self, topics, listener=None):
            subscribed.extend(topics)

    class FakeProducer:
        def __init__(self, **_options):
            pass

        async def start(self):
            raise StopRun

        async def send_and_wait(self, topic, value=None, key=None, headers=None):
            sent.append(topic)

    monkeypatch.setattr(runner_module, "AIOKafkaConsumer", FakeConsumer)
    monkeypatch.setattr(runner_module, "AIOKafkaProducer", FakeProducer)
    settings = Settings(inbound_topic="conformance.inbound", outbound_topic="conformance.outbound")
    runner = runner_module.Runner(settings)

    with pytest.raises(StopRun):
        await runner.run()
    await runner.publish(b"k", b"v", [])

    assert subscribed == ["conformance.inbound"]
    assert sent == ["conformance.outbound"]

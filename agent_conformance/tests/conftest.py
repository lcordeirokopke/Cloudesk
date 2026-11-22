"""Fixtures do kit: Core falso, produtor, coletor das ações, schemas do contrato e espera do agente.

O Core falso, o produtor e o coletor sobem uma vez por execução. Antes do primeiro caso, o kit
espera o agente sob teste responder a um evento de aquecimento (STARTUP_TIMEOUT_SECONDS), porque
a entrada do agente no grupo de consumo leva alguns segundos.
"""

import json

import pytest
import pytest_asyncio
from jsonschema import Draft202012Validator

from agent_conformance import builders
from agent_conformance.config import Settings
from agent_conformance.fake_core import FakeCore
from agent_conformance.kafka import InboundProducer, OutboundCollector

STARTUP_TIMEOUT_SECONDS = 90


@pytest.fixture(scope="session")
def settings() -> Settings:
    return Settings.from_env()


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="session")
def schema(settings):
    def load(name: str) -> Draft202012Validator:
        return Draft202012Validator(read_json(settings.contracts / "schemas" / f"{name}.json"))
    return load


@pytest.fixture(scope="session")
def vectors(settings):
    def load(name: str) -> dict:
        return read_json(settings.contracts / f"{name}.json")
    return load


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def core(settings):
    if not settings.context_secret:
        pytest.fail("CONFORMANCE_CONTEXT_SECRET não informado")
    fake = FakeCore(settings.context_secret, settings.core_port)
    await fake.start()
    yield fake
    await fake.stop()


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def producer(settings):
    item = InboundProducer(settings.kafka_brokers, settings.inbound_topic)
    await item.start()
    yield item
    await item.stop()


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def outbound(settings):
    item = OutboundCollector(settings.kafka_brokers, settings.outbound_topic)
    await item.start()
    yield item
    await item.stop()


@pytest_asyncio.fixture(scope="session", loop_scope="session")
async def agent(core, producer, outbound):
    """Espera o agente sob teste responder ao evento de aquecimento."""
    warmup = builders.delivery("Oi, tudo bem?")
    core.program(warmup.conversation_id, warmup.event["brand"], builders.context(warmup))
    await producer.publish(warmup.event, warmup.headers)
    if not await outbound.wait(warmup.conversation_id, 1, STARTUP_TIMEOUT_SECONDS):
        pytest.fail(f"o agente sob teste não publicou ação em {STARTUP_TIMEOUT_SECONDS} s")
    return core, producer, outbound

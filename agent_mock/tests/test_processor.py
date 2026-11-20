import json

import pytest
from conftest import CONVERSATION_ID, Record, context_for, event_body, record, schema_validator, without_times

from agent_mock import logs, trace
from agent_mock.config import Settings
from agent_mock.context_client import ContextClient, PermanentContextError, TransientContextError
from agent_mock.processor import Processor

TEXT = "Meu repasse de 12/11/2026 ainda não caiu."


class Harness:
    def __init__(self, contexts=None, settings=None, publish_failures=0):
        self.contexts = contexts
        self.settings = settings or Settings()
        self.published = []
        self.sleeps = []
        self.fetches = []
        self.publish_failures = publish_failures
        self.processor = Processor(self.settings, self.fetch, self.publish, sleep=self.sleep)

    async def fetch(self, event, traceparent):
        self.fetches.append(traceparent)
        result = self.contexts(event) if callable(self.contexts) else self.contexts
        if isinstance(result, Exception):
            raise result
        return result

    async def publish(self, key, value, headers):
        if self.publish_failures:
            self.publish_failures -= 1
            raise ConnectionError("Kafka fora")
        self.published.append((key, json.loads(value), headers))

    async def sleep(self, delay):
        self.sleeps.append(delay)


async def test_publica_a_acao_com_chave_headers_e_carimbos(action_validator):
    body = event_body(text=TEXT)
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    key, value, headers = harness.published[0]
    assert key == CONVERSATION_ID.encode()
    assert value == outcome.action
    assert action_validator.is_valid(value)
    assert value["based_on_sequence"] == 7
    assert value["timestamps"]["broker_received_at"] == "2026-11-13T14:02:11.530Z"
    assert value["timestamps"]["kafka_appended_at"] == "2026-11-13T14:02:11.541Z"
    assert value["timestamps"]["agent_consumed_at"] <= value["timestamps"]["agent_published_at"]
    header_map = {name: raw.decode() for name, raw in headers}
    assert schema_validator("kafka.outbound-headers").is_valid(header_map)
    assert header_map == {"brand": "infinitepay", "traceparent": value["traceparent"]}


async def test_traceparent_continua_o_header_do_kafka():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    published = trace.parse(outcome.action["traceparent"])
    assert published.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736"
    assert published.parent_id != "00f067aa0ba902b7"
    assert harness.fetches == [outcome.action["traceparent"]]


async def test_descarta_quando_o_contexto_tem_mensagem_mais_nova():
    body = event_body(text=TEXT, sequence=7)
    context = context_for(body, messages=[
        {"sequence": 7, "author": "customer", "channel": "whatsapp", "text": TEXT, "created_at": "2026-11-13T14:02:11.482Z"},
        {"sequence": 8, "author": "ai", "channel": "whatsapp", "text": "ok", "created_at": "2026-11-13T14:02:12.000Z"},
        {"sequence": 9, "author": "customer", "channel": "whatsapp", "text": "Obrigado", "created_at": "2026-11-13T14:02:13.000Z"},
    ])
    harness = Harness(context)

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.DISCARDED_NEWER
    assert harness.published == []


async def test_mensagem_mais_nova_de_outro_autor_nao_descarta():
    body = event_body(text=TEXT, sequence=7)
    context = context_for(body, messages=[
        {"sequence": 7, "author": "customer", "channel": "whatsapp", "text": TEXT, "created_at": "2026-11-13T14:02:11.482Z"},
        {"sequence": 8, "author": "system", "channel": "whatsapp", "text": "aviso", "created_at": "2026-11-13T14:02:12.000Z"},
    ])
    harness = Harness(context)

    assert (await harness.processor.handle(record(body))).result == logs.PUBLISHED


@pytest.mark.parametrize("state", ["triage", "awaiting_human", "with_human", "resolved", "closed"])
async def test_descarta_conversa_fora_de_with_ai(state):
    body = event_body(text=TEXT)
    harness = Harness(context_for(body, state=state))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.DISCARDED_STATE
    assert harness.published == []


async def test_descarta_erro_permanente_do_contexto():
    harness = Harness(PermanentContextError(404, "conversa não encontrada"))

    outcome = await harness.processor.handle(record(event_body(text=TEXT)))

    assert outcome.result == logs.CONTEXT_ERROR
    assert harness.published == []


async def test_registro_invalido():
    harness = Harness()

    outcome = await harness.processor.handle(Record(value=b"{nao e json", offset=3))

    assert outcome.result == logs.INVALID_EVENT
    assert harness.fetches == []


async def test_registro_sem_header_broker_received_at():
    body = event_body(text=TEXT)
    broken = record(body)
    broken.headers = [item for item in broken.headers if item[0] != "broker_received_at"]

    assert (await Harness().processor.handle(broken)).result == logs.INVALID_EVENT


async def test_marca_sem_locale():
    body = event_body(text=TEXT, brand="outra")
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.UNKNOWN_BRAND
    assert harness.fetches == []


async def test_repete_o_erro_transitorio_do_contexto():
    body = event_body(text=TEXT)
    sleeps = []
    answers = [TransientContextError("503"), TransientContextError("rede"), context_for(body)]

    async def sleep(delay):
        sleeps.append(delay)

    client = ContextClient(session=None, settings=Settings(), sleep=sleep)

    async def fetch_once(event, traceparent):
        answer = answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    client.fetch_once = fetch_once
    harness = Harness()
    harness.processor.fetch_context = client.fetch

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert sleeps == [2.0, 4.0]


async def test_latencia_aplicada_antes_da_publicacao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250))

    await harness.processor.handle(record(body))

    assert harness.sleeps == [0.25]


async def test_sem_latencia_por_padrao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body))

    await harness.processor.handle(record(body))

    assert harness.sleeps == []


async def test_repete_a_publicacao_sem_confirmacao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), publish_failures=2)

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert harness.sleeps == [2.0, 4.0]
    assert len(harness.published) == 1


async def test_evento_reentregue_gera_a_mesma_acao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body))

    first = await harness.processor.handle(record(body, offset=10))
    second = await harness.processor.handle(record(body, offset=10))

    assert without_times(first.action) == without_times(second.action)
    assert (first.action["inbound_event_id"], first.action["type"]) == (
        second.action["inbound_event_id"], second.action["type"])


async def test_mesma_mensagem_em_conversas_distintas_gera_a_mesma_decisao():
    other = "019a8f3d-22bb-7b02-8c55-0a1b2c3d4e5f"
    first_body = event_body(text=TEXT)
    second_body = event_body(text=TEXT, conversation_id=other, event_id="019a8f3e-6c8b-7c21-9d43-1f2e3a4b5c6d")
    harness = Harness(lambda event: context_for(first_body if event.conversation_id == CONVERSATION_ID else second_body))

    first = (await harness.processor.handle(record(first_body))).action
    second = (await harness.processor.handle(record(second_body))).action

    def decision_of(item):
        kept = without_times(item)
        for key in ("inbound_event_id", "conversation_id"):
            kept.pop(key)
        return kept

    assert decision_of(first) == decision_of(second)

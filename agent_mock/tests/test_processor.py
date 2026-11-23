import json

import pytest
from conftest import (
    CONVERSATION_ID, Record, context_for, event_body, memory_entry, record, schema_validator, with_memory, without_times,
)

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


async def test_modo_none_nao_altera_a_publicacao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="none", failure_delay_ms=900))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert len(harness.published) == 1
    assert harness.sleeps == []
    assert outcome.action["based_on_sequence"] == 7


async def test_modo_delay_soma_o_atraso_a_latencia():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_mode="delay", failure_delay_ms=1000))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert harness.sleeps == [1.25]
    assert len(harness.published) == 1


async def test_modo_drop_termina_sem_publicar():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="drop"))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.FAILURE_DROP
    assert outcome.action is None
    assert harness.published == []


async def test_modo_duplicate_publica_a_mesma_acao_duas_vezes():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="duplicate"))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert len(harness.published) == 2
    assert harness.published[0] == harness.published[1]
    assert harness.published[0][1] == outcome.action


async def test_modo_duplicate_repete_a_segunda_publicacao_sem_confirmacao():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="duplicate"))
    original_publish = harness.publish
    calls = []

    async def publish(key, value, headers):
        calls.append(value)
        if len(calls) == 2:
            raise ConnectionError("Kafka fora")
        await original_publish(key, value, headers)

    harness.processor.publish = publish

    await harness.processor.handle(record(body))

    assert len(harness.published) == 2
    assert calls[1] == calls[2]
    assert harness.sleeps == [2.0]


async def test_modo_stale_publica_com_based_on_sequence_menos_1(action_validator):
    body = event_body(text=TEXT, sequence=7)
    harness = Harness(context_for(body), settings=Settings(failure_mode="stale"))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert len(harness.published) == 1
    assert outcome.action["based_on_sequence"] == 6
    assert action_validator.is_valid(outcome.action)


async def test_modo_stale_com_sequence_1_publica_sem_alteracao():
    body = event_body(text=TEXT, sequence=1)
    harness = Harness(context_for(body), settings=Settings(failure_mode="stale"))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.FAILURE_STALE_SKIPPED
    assert outcome.action["based_on_sequence"] == 1
    assert len(harness.published) == 1


async def test_evento_nao_afetado_pela_taxa_publica_normal():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="drop", failure_rate=0))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert len(harness.published) == 1


async def test_log_do_published_afetado_leva_o_modo(capsys):
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(failure_mode="duplicate"))

    await harness.processor.handle(record(body))

    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    processed = [line for line in lines if line.get("result") == logs.PUBLISHED]
    assert processed[-1]["failure"] == "duplicate"


@pytest.mark.parametrize("received_at", [None, "2026-11-13 14:02:11"])
async def test_evento_sem_received_at_valido_e_descartado(received_at):
    body = event_body(text=TEXT)
    if received_at is None:
        del body["received_at"]
    else:
        body["received_at"] = received_at
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.INVALID_EVENT
    assert harness.fetches == []


async def test_repassa_a_janela_da_memoria_a_decisao():
    body = event_body(text="Quando cai o repasse?")
    context = with_memory(context_for(body), memory_entry(resolved_at="2026-11-03T10:00:00.000Z"))

    inside = await Harness(context, settings=Settings(memory_window_days=30)).processor.handle(record(body))
    outside = await Harness(context, settings=Settings(memory_window_days=5)).processor.handle(record(body))

    assert inside.action["text"].startswith("Vi que você já falou com a gente sobre repasse em 03/11/2026. ")
    assert not outside.action["text"].startswith("Vi que")


GREETING = "Oi, tudo bem? Preciso de ajuda."


def process_lines(capsys):
    return [json.loads(line) for line in capsys.readouterr().out.splitlines()]


async def test_marcador_vence_modo_none_e_taxa_zero():
    body = event_body(text=f"{GREETING} [falha:drop]")
    harness = Harness(context_for(body), settings=Settings(failure_mode="none", failure_rate=0))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.FAILURE_DROP
    assert harness.published == []


async def test_marcador_vence_outro_modo_da_configuracao():
    body = event_body(text=f"[falha:duplicate] {GREETING}")
    harness = Harness(context_for(body), settings=Settings(failure_mode="drop", failure_rate=1))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert len(harness.published) == 2


async def test_delay_do_marcador_com_valor_soma_o_valor():
    body = event_body(text=f"{GREETING} [falha:delay=50000]")
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_delay_ms=1000))

    await harness.processor.handle(record(body))

    assert harness.sleeps == [50.25]


async def test_delay_do_marcador_sem_valor_soma_a_configuracao():
    body = event_body(text=f"{GREETING} [falha:delay]")
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_delay_ms=1000))

    await harness.processor.handle(record(body))

    assert harness.sleeps == [1.25]


async def test_stale_do_marcador_com_sequence_1():
    body = event_body(text=f"{GREETING} [falha:stale]", sequence=1)
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.FAILURE_STALE_SKIPPED
    assert outcome.action["based_on_sequence"] == 1


async def test_stale_do_marcador_publica_com_based_on_sequence_menos_1():
    body = event_body(text=f"{GREETING} [falha:stale]", sequence=3)
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert outcome.result == logs.PUBLISHED
    assert outcome.action["based_on_sequence"] == 2


@pytest.mark.parametrize("text", [GREETING, TEXT, "Quero mudar o endereço cadastrado."])
async def test_decisao_feita_sobre_o_texto_sem_marcador(text):
    marked = event_body(text=f"{text} [falha:duplicate]")
    plain = event_body(text=text)

    with_marker = (await Harness(context_for(marked)).processor.handle(record(marked))).action
    without_marker = (await Harness(context_for(plain)).processor.handle(record(plain))).action

    assert without_times(with_marker) == without_times(without_marker)


async def test_marcador_lido_no_texto_do_contexto():
    body = event_body(text=GREETING, sequence=7)
    context = context_for(body, messages=[
        {"sequence": 7, "author": "customer", "channel": "whatsapp", "text": f"{GREETING} [falha:drop]",
         "created_at": "2026-11-13T14:02:11.482Z"},
    ])

    outcome = await Harness(context).processor.handle(record(body))

    assert outcome.result == logs.FAILURE_DROP


async def test_log_leva_a_origem_da_falha(capsys):
    marked = event_body(text=f"{GREETING} [falha:duplicate]")
    configured = event_body(text=GREETING)

    await Harness(context_for(marked)).processor.handle(record(marked))
    by_marker = [line for line in process_lines(capsys) if line.get("result")][-1]
    await Harness(context_for(configured), settings=Settings(failure_mode="duplicate")).processor.handle(
        record(configured))
    by_config = [line for line in process_lines(capsys) if line.get("result")][-1]
    await Harness(context_for(configured)).processor.handle(record(configured))
    unaffected = [line for line in process_lines(capsys) if line.get("result")][-1]

    assert (by_marker["failure"], by_marker["failure_source"]) == ("duplicate", "marker")
    assert (by_config["failure"], by_config["failure_source"]) == ("duplicate", "config")
    assert "failure" not in unaffected and "failure_source" not in unaffected


async def test_drop_do_marcador_no_log(capsys):
    body = event_body(text=f"{GREETING} [falha:drop]")

    await Harness(context_for(body)).processor.handle(record(body))

    line = [line for line in process_lines(capsys) if line.get("result")][-1]
    assert (line["result"], line["failure"], line["failure_source"]) == (logs.FAILURE_DROP, "drop", "marker")


def artificial_latency(published_action):
    return published_action["model"]["parameters"]["artificial_latency_ms"]


async def test_acao_leva_o_model_com_a_latencia_artificial(action_validator):
    import importlib.metadata

    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250))

    outcome = await harness.processor.handle(record(body))

    assert outcome.action["model"] == {"name": "agent-mock", "version": importlib.metadata.version("agent-mock"),
                                       "parameters": {"artificial_latency_ms": 250}}
    assert action_validator.is_valid(outcome.action)


async def test_model_sem_latencia_artificial_leva_zero():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body))

    outcome = await harness.processor.handle(record(body))

    assert artificial_latency(outcome.action) == 0


async def test_model_soma_o_atraso_do_modo_delay_da_configuracao(action_validator):
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_mode="delay", failure_delay_ms=1000))

    outcome = await harness.processor.handle(record(body))

    assert artificial_latency(outcome.action) == 1250
    assert action_validator.is_valid(outcome.action)


async def test_model_soma_o_atraso_do_marcador_delay():
    with_value = event_body(text=f"{GREETING} [falha:delay=50000]")
    without_value = event_body(text=f"{GREETING} [falha:delay]")
    settings = Settings(latency_ms=250, failure_delay_ms=1000)

    by_value = await Harness(context_for(with_value), settings=settings).processor.handle(record(with_value))
    by_config = await Harness(context_for(without_value), settings=settings).processor.handle(record(without_value))

    assert artificial_latency(by_value.action) == 50250
    assert artificial_latency(by_config.action) == 1250


async def test_model_do_evento_fora_do_modo_delay_nao_soma_o_atraso():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_mode="delay", failure_delay_ms=1000,
                                                           failure_rate=0))

    outcome = await harness.processor.handle(record(body))

    assert artificial_latency(outcome.action) == 250


async def test_acao_duplicada_leva_o_mesmo_model():
    body = event_body(text=TEXT)
    harness = Harness(context_for(body), settings=Settings(latency_ms=250, failure_mode="duplicate"))

    await harness.processor.handle(record(body))

    first, second = (value for _, value, _ in harness.published)
    assert first["model"] == second["model"]
    assert artificial_latency(first) == 250

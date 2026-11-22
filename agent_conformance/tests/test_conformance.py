"""Conformidade do agente sob teste com o contrato v1.

O kit não exige determinismo: confere forma, coerência e comportamento observável. Cada caso usa
uma conversa nova, programa o contexto no Core falso, publica os eventos no tópico de entrada e
espera as ações da conversa no tópico de saída, ou a ausência delas.
"""

import pytest

from agent_conformance import builders

pytestmark = pytest.mark.asyncio(loop_scope="session")

GREETING = "Oi, tudo bem? Preciso de ajuda."
UNKNOWN = "Quero mudar o endereço cadastrado."
ESCALATION_FIELDS = {"intent", "entities", "tools", "attempts", "sentiment", "suggested_next_step", "confidence"}


def idempotency_key(action: dict) -> str:
    """Idempotency-Key que o Broker calcula: <inbound_event_id>:<type>."""
    return f"{action['inbound_event_id']}:{action['type']}"


async def deliver(agent, item, *responses):
    core, producer, _outbound = agent
    core.program(item.conversation_id, item.event["brand"], *(responses or (builders.context(item),)))
    return await producer.publish(item.event, item.headers)


async def single_action(agent, settings, item):
    actions = await agent[2].wait(item.conversation_id, 1, settings.action_timeout_seconds)
    assert actions, f"nenhuma ação em {settings.action_timeout_seconds} s"
    return actions[0]


async def assert_no_action(agent, settings, item, reads=1):
    """O agente lê o contexto e não publica ação durante o tempo de silêncio."""
    core, _producer, outbound = agent
    requests = await core.wait_requests(item.conversation_id, reads, settings.action_timeout_seconds)
    assert len(requests) >= reads, "o agente não leu o contexto"
    assert await outbound.wait(item.conversation_id, 1, settings.quiet_seconds) == []


async def test_leitura_do_contexto(agent, settings):
    item = builders.delivery(GREETING)
    await deliver(agent, item)

    await single_action(agent, settings, item)

    request = agent[0].requests_for(item.conversation_id)[0]
    assert request.signature_problem is None
    assert request.path == item.event["context_url"]
    assert request.brand == item.event["brand"]
    assert "traceparent" in {name.lower() for name in request.headers}
    traceparent = next(value for name, value in request.headers.items() if name.lower() == "traceparent")
    assert builders.trace_id(traceparent) == builders.trace_id(item.headers["traceparent"])


async def test_acao_valida(agent, settings, schema):
    item = builders.delivery(GREETING, sequence=3)
    published = await deliver(agent, item)

    action = await single_action(agent, settings, item)

    value = action.value
    assert [error.message for error in schema("action").iter_errors(value)] == []
    assert action.key == item.conversation_id.encode("utf-8")
    assert [error.message for error in schema("kafka.outbound-headers").iter_errors(action.headers)] == []
    assert value["inbound_event_id"] == item.event["event_id"]
    assert value["brand"] == item.event["brand"] == action.headers["brand"]
    assert value["conversation_id"] == item.conversation_id
    assert value["based_on_sequence"] == item.event["sequence"]
    assert value["timestamps"]["broker_received_at"] == item.headers["broker_received_at"]
    assert value["timestamps"]["kafka_appended_at"] == builders.from_millis(published.timestamp_ms)
    assert builders.trace_id(value["traceparent"]) == builders.trace_id(item.headers["traceparent"])
    assert action.headers["traceparent"] == value["traceparent"]


async def test_reentrega_gera_a_mesma_idempotency_key(agent, settings):
    core, producer, outbound = agent
    item = builders.delivery(GREETING)
    await deliver(agent, item)
    await producer.publish(item.event, item.headers)

    actions = await outbound.wait(item.conversation_id, 2, settings.action_timeout_seconds)

    assert len(actions) >= 2, "a reentrega não gerou nova ação"
    assert len({idempotency_key(action.value) for action in actions}) == 1
    assert idempotency_key(actions[0].value) == f"{item.event['event_id']}:{actions[0].value['type']}"


async def test_mensagem_mais_nova_no_contexto_nao_gera_acao(agent, settings):
    item = builders.delivery(GREETING, sequence=1)
    newer = {"sequence": 2, "author": "customer", "channel": "whatsapp", "text": "Obrigado!",
             "created_at": builders.now()}
    await deliver(agent, item, builders.context(item, extra_messages=[newer]))

    await assert_no_action(agent, settings, item)


async def test_conversa_fora_da_ia_nao_gera_acao(agent, settings):
    item = builders.delivery(GREETING)
    await deliver(agent, item, builders.context(item, state="awaiting_human"))

    await assert_no_action(agent, settings, item)


async def test_erro_permanente_do_contexto_nao_trava_o_agente(agent, settings):
    failing = builders.delivery(GREETING)
    await deliver(agent, failing, (404, {"error": "not_found"}))
    await assert_no_action(agent, settings, failing)

    following = builders.delivery(GREETING)
    await deliver(agent, following)

    await single_action(agent, settings, following)


async def test_erro_transitorio_do_contexto_e_repetido(agent, settings):
    item = builders.delivery(GREETING)
    await deliver(agent, item, (503, {"error": "unavailable"}), builders.context(item))

    await single_action(agent, settings, item)

    statuses = [request.status for request in agent[0].requests_for(item.conversation_id)]
    assert len(statuses) >= 2
    assert statuses[0] == 503 and statuses[-1] == 200
    assert len(agent[2].actions(item.conversation_id)) == 1


async def test_escalacao_leva_o_contexto_estruturado(agent, settings, schema):
    item = builders.delivery(UNKNOWN)
    await deliver(agent, item)

    action = (await single_action(agent, settings, item)).value

    if action["type"] != "escalate":
        pytest.skip(f"o agente sob teste respondeu {action['type']} ao texto sem intenção")
    assert [error.message for error in schema("action").iter_errors(action)] == []
    assert set(action["context"]) == ESCALATION_FIELDS
    assert 0 <= action["context"]["confidence"] <= 1
    assert action["reason"] and action["summary"]

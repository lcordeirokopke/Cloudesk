import pytest
from conftest import CONTRACTS, FIXTURES, context_for, event_body, read_json, record, schema_validator
from test_decision import find, find_date

from agent_mock import action, decision, events, tools, trace

CORPUS = read_json(FIXTURES / "intent_corpus.json")
BRAND_OF = {"pt-BR": "infinitepay", "en-US": "jim"}
TRACEPARENT = str(trace.continue_trace("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"))


def br(iso, locale):
    year, month, day = iso.split("-")
    return f"{day}/{month}/{year}" if locale == "pt-BR" else f"{month}/{day}/{year}"


def table_texts():
    """Textos que passam por todas as linhas da tabela de decisão, nos dois locales."""
    texts = [(entry["locale"], entry["text"]) for entry in CORPUS]
    for status in ("aprovada", "estornada", "contestada", "nao_encontrada"):
        transaction_id = find("TX", 10, tools.consultar_transacao, status)
        texts += [("pt-BR", f"Podem verificar a transação {transaction_id}?"),
                  ("en-US", f"Can you check transaction {transaction_id}?")]
    for status in ("pago", "agendado", "nao_encontrado"):
        day = find_date(status)
        texts += [("pt-BR", f"Meu repasse de {br(day, 'pt-BR')} ainda não caiu."),
                  ("en-US", f"My payout from {br(day, 'en-US')} has not arrived yet.")]
    for status in ("online", "offline", "defeito"):
        serial = find("SN", 8, tools.status_maquininha, status)
        texts += [("pt-BR", f"A maquininha {serial} não liga."), ("en-US", f"Card reader {serial} is broken.")]
    return texts


def generate(locale, text):
    body = event_body(text=text, brand=BRAND_OF[locale])
    event = events.parse(record(body))
    chosen = decision.decide(event, context_for(body), locale)
    return action.build(event, chosen, traceparent=TRACEPARENT, consumed_at="2026-11-13T14:02:11.560Z",
                        published_at="2026-11-13T14:02:11.905Z")


ACTIONS = [generate(locale, text) for locale, text in table_texts()]


def test_tabela_gera_os_tres_tipos_de_acao():
    assert {item["type"] for item in ACTIONS} == {"reply", "escalate", "resolve"}
    reasons = {item["reason"] for item in ACTIONS if item["type"] == "escalate"}
    assert reasons == set(decision.ESCALATIONS)


@pytest.mark.parametrize("generated", ACTIONS, ids=lambda item: f"{item['type']}:{item.get('reason', '')}")
def test_acao_gerada_segue_o_schema(generated, action_validator):
    errors = [error.message for error in action_validator.iter_errors(generated)]

    assert errors == []


def test_campos_da_acao():
    generated = ACTIONS[0]

    assert generated["inbound_event_id"] == "019a8f3e-5b7a-7c21-9d43-1f2e3a4b5c6d"
    assert generated["based_on_sequence"] == 7
    assert generated["timestamps"] == {
        "broker_received_at": "2026-11-13T14:02:11.530Z",
        "kafka_appended_at": "2026-11-13T14:02:11.541Z",
        "agent_consumed_at": "2026-11-13T14:02:11.560Z",
        "agent_published_at": "2026-11-13T14:02:11.905Z",
    }


def test_headers_seguem_o_schema():
    validator = schema_validator("kafka.outbound-headers")

    for generated in ACTIONS:
        assert validator.is_valid(action.headers(generated))


@pytest.mark.parametrize("vector", read_json(CONTRACTS / "idempotency-key-vectors.json")["vectors"],
                         ids=lambda vector: vector["type"])
def test_idempotency_key_dos_vetores(vector):
    built = {"inbound_event_id": vector["inbound_event_id"], "type": vector["type"]}

    assert action.idempotency_key(built) == vector["idempotency_key"]


def test_idempotency_key_da_acao_gerada():
    for generated in ACTIONS:
        assert action.idempotency_key(generated) == f"{generated['inbound_event_id']}:{generated['type']}"


def test_valor_codificado_e_json_da_acao():
    import json

    assert json.loads(action.encode(ACTIONS[0])) == ACTIONS[0]


def test_escalacoes_com_a_confianca_por_regra_seguem_o_schema(action_validator):
    from conftest import memory_entry, with_memory

    escalations = [item for item in ACTIONS if item["type"] == "escalate"]
    assert {item["context"]["confidence"] for item in escalations} == {0.8, 0.5, 0.2}

    serial = find("SN", 8, tools.status_maquininha, "defeito")
    body = event_body(text=f"A maquininha {serial} não liga.")
    context = with_memory(context_for(body), memory_entry(category="maquininha",
                                                          resolved_at="2026-11-03T10:00:00.000Z"))
    event = events.parse(record(body))
    generated = action.build(event, decision.decide(event, context, "pt-BR"), traceparent=TRACEPARENT,
                             consumed_at="2026-11-13T14:02:11.560Z", published_at="2026-11-13T14:02:11.905Z")

    assert generated["context"]["confidence"] == 0.7
    assert generated["context"]["attempts"][-1].startswith("Confiança 0,7: ")
    assert [error.message for error in action_validator.iter_errors(generated)] == []
    for item in escalations:
        assert item["context"]["attempts"][-1].startswith("Confiança ")

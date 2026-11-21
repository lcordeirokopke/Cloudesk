import pytest
from conftest import context_for, event_body, memory_entry, schema_validator, with_memory

from agent_mock import memory

# received_at do evento de teste: 2026-11-13T14:02:11.482Z.
RECEIVED_AT = event_body()["received_at"]


def context(*entries):
    return with_memory(context_for(event_body()), *entries)


def test_contexto_de_teste_segue_o_schema():
    assert schema_validator("context").is_valid(context(memory_entry(), memory_entry(category=None)))


@pytest.mark.parametrize("intent, categories", [
    ("transacao", ("transacao", "transaction")),
    ("repasse", ("repasse", "payout")),
    ("taxas", ("taxas", "fees")),
    ("maquininha", ("maquininha", "card_reader")),
])
def test_equivale_as_categorias_das_duas_marcas(intent, categories):
    for category in categories:
        entry = memory_entry(category=category)

        assert memory.previous(context(entry), intent, RECEIVED_AT, 30) == entry


def test_categoria_de_outra_intencao_nao_conta():
    assert memory.previous(context(memory_entry(category="taxas")), "repasse", RECEIVED_AT, 30) is None


def test_intencao_sem_categoria_nao_usa_a_memoria():
    assert memory.previous(context(memory_entry()), "saudacao", RECEIVED_AT, 30) is None


@pytest.mark.parametrize("resolved_at, found", [
    ("2026-11-13T14:02:11.482Z", True),
    ("2026-10-14T14:02:11.482Z", True),
    ("2026-10-14T14:02:11.481Z", False),
    ("2026-11-13T14:02:11.483Z", False),
])
def test_janela_pelo_received_at_do_evento(resolved_at, found):
    entry = memory_entry(resolved_at=resolved_at)

    assert (memory.previous(context(entry), "repasse", RECEIVED_AT, 30) == entry) is found


def test_janela_zero_aceita_so_o_mesmo_instante():
    entry = memory_entry(resolved_at=RECEIVED_AT)

    assert memory.previous(context(entry), "repasse", RECEIVED_AT, 0) == entry
    assert memory.previous(context(memory_entry(resolved_at="2026-11-13T14:02:11.000Z")), "repasse", RECEIVED_AT, 0) is None


def test_escolhe_a_conversa_mais_recente():
    older = memory_entry(category="payout", resolved_at="2026-11-01T10:00:00.000Z", first_message="antiga")
    newer = memory_entry(category="repasse", resolved_at="2026-11-10T10:00:00.000Z", first_message="nova")
    other = memory_entry(category="taxas", resolved_at="2026-11-12T10:00:00.000Z")

    assert memory.previous(context(other, older, newer), "repasse", RECEIVED_AT, 30) == newer


def test_memoria_null_ou_conversa_sem_categoria():
    assert memory.previous(context_for(event_body()), "repasse", RECEIVED_AT, 30) is None
    assert memory.previous(context(memory_entry(category=None)), "repasse", RECEIVED_AT, 30) is None

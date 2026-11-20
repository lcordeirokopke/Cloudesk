import pytest
from conftest import FIXTURES, read_json

from agent_mock import intents

CORPUS = read_json(FIXTURES / "intent_corpus.json")


@pytest.mark.parametrize("entry", CORPUS, ids=lambda entry: f"{entry['locale']}:{entry['text'][:40]}")
def test_corpus_cai_na_intencao_esperada(entry):
    assert intents.classify(entry["text"], entry["locale"]) == entry["intent"]


def test_corpus_cobre_todas_as_intencoes_nos_dois_locales():
    covered = {(entry["locale"], entry["intent"]) for entry in CORPUS}

    for locale in ("pt-BR", "en-US"):
        for intent in (*intents.INTENTS, intents.UNKNOWN):
            assert (locale, intent) in covered


def test_ignora_caixa_e_acentos():
    assert intents.classify("TRANSAÇÃO pendente", "pt-BR") == "transacao"


def test_casa_so_palavra_inteira():
    assert intents.classify("taxativo", "pt-BR") == intents.UNKNOWN


def test_conta_so_a_expressao_mais_longa_do_trecho():
    # "muito obrigado" conta uma vez, sem somar "obrigado" de novo.
    assert intents.scores("muito obrigado", "pt-BR")["agradecimento"] == 1


def test_empate_fica_com_a_ordem_da_lista():
    assert intents.scores("repasse taxa", "pt-BR")["repasse"] == intents.scores("repasse taxa", "pt-BR")["taxas"]
    assert intents.classify("repasse taxa", "pt-BR") == "repasse"


def test_vence_a_maior_pontuacao():
    assert intents.classify("Olá, a transação está pendente no extrato", "pt-BR") == "transacao"

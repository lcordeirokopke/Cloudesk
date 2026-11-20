from agent_mock import entities


def test_extrai_transacao_valor_e_data_em_pt_br():
    text = "Olá, a transação TX4815162342 de R$ 1.532,40 do dia 12/11/2026 não aparece no meu extrato."

    assert entities.extract(text, "pt-BR") == {
        "id_transacao": "TX4815162342", "data": "2026-11-12", "valor": "1532.40",
    }


def test_extrai_data_e_valor_em_en_us():
    text = "My payout from 11/12/2026 for $1,532.40 has not arrived yet."

    assert entities.extract(text, "en-US") == {"data": "2026-11-12", "valor": "1532.40"}


def test_extrai_numero_de_serie():
    assert entities.extract("A maquininha sn12345678 não liga.", "pt-BR") == {"numero_serie": "SN12345678"}


def test_valor_sem_separador_de_milhar():
    assert entities.extract("Fui cobrado R$ 12,50 de taxa", "pt-BR") == {"valor": "12.50"}
    assert entities.extract("charged a $1234.56 fee", "en-US") == {"valor": "1234.56"}


def test_ignora_ids_com_tamanho_errado():
    assert entities.extract("TX123 e SN1234567890 e TX12345678901", "pt-BR") == {}


def test_ignora_data_inexistente():
    assert entities.extract("Repasse de 31/02/2026", "pt-BR") == {}
    assert entities.extract("Payout from 13/01/2026", "en-US") == {}


def test_sem_entidade():
    assert entities.extract("Oi, tudo bem?", "pt-BR") == {}

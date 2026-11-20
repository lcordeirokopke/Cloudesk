import pytest
from conftest import context_for, event_body, record, without_times

from agent_mock import decision, events, tools
from agent_mock.action import build


def find(prefix, digits, tool, status):
    """Primeiro id sintético cujo retorno da ferramenta tem o status pedido."""
    key = "id_transacao" if prefix == "TX" else "numero_serie"
    for index in range(10_000):
        identifier = f"{prefix}{10 ** (digits - 1) + index}"
        if tool({key: identifier})["status"] == status:
            return identifier
    raise AssertionError(f"nenhum id com {status}")


def find_date(status):
    for day in range(1, 29):
        value = f"2026-10-{day:02d}"
        if tools.consultar_repasse({"data": value})["status"] == status:
            return value
    raise AssertionError(f"nenhuma data com {status}")


def decide(text, brand="infinitepay", locale="pt-BR"):
    body = event_body(text=text, brand=brand)
    event = events.parse(record(body))
    return decision.decide(event, context_for(body), locale)


def br_date(iso):
    year, month, day = iso.split("-")
    return f"{day}/{month}/{year}"


def test_agradecimento_resolve():
    result = decide("Obrigado, deu tudo certo!")

    assert result.type == "resolve"
    assert result.fields == {"reason": "lojista_confirmou"}
    assert result.tools == []


def test_saudacao_pede_o_assunto():
    result = decide("Oi, tudo bem? Preciso de ajuda.")

    assert result.type == "reply"
    assert result.fields["text"] == decision.REPLIES["pt-BR"]["saudacao"]


def test_transacao_sem_id_pede_o_id():
    result = decide("A transação ficou pendente.")

    assert result.type == "reply"
    assert result.fields["text"] == decision.REPLIES["pt-BR"]["pedir_transacao"]
    assert result.tools == []


@pytest.mark.parametrize("status", ["aprovada", "estornada"])
def test_transacao_encontrada_responde(status):
    transaction_id = find("TX", 10, tools.consultar_transacao, status)
    output = tools.consultar_transacao({"id_transacao": transaction_id})

    result = decide(f"Podem verificar a transação {transaction_id}?")

    assert result.type == "reply"
    assert transaction_id in result.fields["text"]
    assert br_date(output["data"]) in result.fields["text"]
    assert [call["name"] for call in result.tools] == ["consultar_transacao"]
    assert result.tools[0]["input"] == {"id_transacao": transaction_id}


@pytest.mark.parametrize(("status", "reason"), [
    ("contestada", "transacao_contestada"), ("nao_encontrada", "transacao_nao_localizada"),
])
def test_transacao_contestada_ou_ausente_escala(status, reason):
    transaction_id = find("TX", 10, tools.consultar_transacao, status)

    result = decide(f"O cliente foi cobrado duas vezes na transação {transaction_id}.")

    assert result.type == "escalate"
    assert result.fields["reason"] == reason
    context = result.fields["context"]
    assert context["intent"] == "transacao"
    assert context["entities"] == {"id_transacao": transaction_id}
    output = tools.consultar_transacao({"id_transacao": transaction_id})
    assert output["status"] == status
    assert context["tools"] == [{"name": "consultar_transacao", "output": output}]
    assert context["sentiment"] == "negative"
    assert context["suggested_next_step"] == decision.ESCALATIONS[reason][0]
    assert context["confidence"] == decision.ESCALATIONS[reason][1]
    assert context["attempts"]


@pytest.mark.parametrize("status", ["pago", "agendado"])
def test_repasse_encontrado_responde(status):
    day = find_date(status)

    result = decide(f"Meu repasse de {br_date(day)} no valor de R$ 100,00 caiu?")

    assert result.type == "reply"
    assert "R$ " in result.fields["text"]
    assert result.tools[0]["input"] == {"data": day}


def test_repasse_sem_data_consulta_sem_data():
    result = decide("Quando cai o repasse?")

    assert result.tools[0]["input"] == {}


def test_repasse_nao_encontrado_escala():
    day = find_date("nao_encontrado")

    result = decide(f"Meu repasse de {br_date(day)} ainda não caiu.")

    assert result.type == "escalate"
    assert result.fields["reason"] == "repasse_nao_localizado"
    assert result.fields["context"]["sentiment"] == "negative"
    assert result.fields["context"]["entities"] == {"data": day}


def test_taxas_responde_com_a_tabela_da_marca():
    result = decide("Qual a taxa do crédito parcelado em 12x?")

    assert result.type == "reply"
    assert result.fields["text"] == (
        "As taxas da sua conta são: débito 1,37%, crédito à vista 3,15%, crédito em 12x 12,40% e Pix 0,00%."
    )
    assert result.tools[0]["input"] == {"marca": "infinitepay"}


def test_taxas_em_en_us():
    result = decide("What is the fee for credit card installments?", brand="jim", locale="en-US")

    assert result.fields["text"] == (
        "Your account fees are: debit 1.50%, credit 2.90%, credit in 12 installments 11.90% and instant payment 0.00%."
    )


def test_maquininha_sem_serie_pede_a_serie():
    result = decide("Minha maquininha não liga.")

    assert result.fields["text"] == decision.REPLIES["pt-BR"]["pedir_serie"]


@pytest.mark.parametrize("status", ["online", "offline"])
def test_maquininha_responde_com_passos(status):
    serial = find("SN", 8, tools.status_maquininha, status)

    result = decide(f"A maquininha {serial} mostra erro de conexão.")

    assert result.type == "reply"
    assert result.fields["text"] == decision.REPLIES["pt-BR"][status].format(serie=serial)


def test_maquininha_com_defeito_escala_para_troca():
    serial = find("SN", 8, tools.status_maquininha, "defeito")

    result = decide(f"Preciso trocar a maquininha {serial}.")

    assert result.type == "escalate"
    assert result.fields["reason"] == "maquininha_com_defeito"
    assert result.fields["context"]["sentiment"] == "neutral"


def test_intencao_desconhecida_escala():
    result = decide("Quero mudar o endereço cadastrado.")

    assert result.type == "escalate"
    assert result.fields["reason"] == "intencao_nao_identificada"
    assert result.fields["context"]["intent"] == "desconhecida"
    assert result.fields["context"]["tools"] == []


def test_texto_decidido_vem_do_contexto():
    body = event_body(text="Oi")
    context = context_for(body, messages=[
        {"sequence": 7, "author": "customer", "channel": "whatsapp", "text": "Obrigado!",
         "created_at": "2026-11-13T14:02:11.482Z"},
    ])

    assert decision.decide(events.parse(record(body)), context, "pt-BR").type == "resolve"


def test_texto_do_evento_quando_o_contexto_nao_traz_a_sequence():
    body = event_body(text="Obrigado!")

    assert decision.decide(events.parse(record(body)), context_for(body, messages=[]), "pt-BR").type == "resolve"


def test_mesma_entrada_mesma_acao():
    body = event_body(text="Fiz uma venda de R$ 1.532,40 em 12/11/2026 (id TX4815162342) e foi cobrado duas vezes.")
    event = events.parse(record(body))

    actions = [
        without_times(build(event, decision.decide(event, context_for(body), "pt-BR"),
                            traceparent="00-" + "a" * 32 + "-" + "b" * 16 + "-01",
                            consumed_at="2026-11-13T14:02:11.560Z", published_at="2026-11-13T14:02:11.905Z"))
        for _ in range(3)
    ]

    assert actions[0] == actions[1] == actions[2]

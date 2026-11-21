import pytest
from conftest import context_for, event_body, memory_entry, record, with_memory, without_times

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


MEMORY_CASES = [
    ("pt-BR", "infinitepay", "A transação ficou pendente.", "transacao", "transação"),
    ("pt-BR", "infinitepay", "Quando cai o repasse?", "repasse", "repasse"),
    ("pt-BR", "infinitepay", "Qual a taxa do crédito parcelado em 12x?", "taxas", "taxas"),
    ("pt-BR", "infinitepay", "Minha maquininha não liga.", "maquininha", "maquininha"),
    ("en-US", "jim", "The transaction is pending.", "transaction", "a transaction"),
    ("en-US", "jim", "When is my payout?", "payout", "payouts"),
    ("en-US", "jim", "What is the fee for credit card installments?", "fees", "fees"),
    ("en-US", "jim", "My card reader is not working.", "card_reader", "your card reader"),
]


def decide_with_memory(text, brand, locale, *entries, window=30):
    body = event_body(text=text, brand=brand)
    event = events.parse(record(body))
    return decision.decide(event, with_memory(context_for(body), *entries), locale, memory_window_days=window)


@pytest.mark.parametrize("locale, brand, text, category, topic", MEMORY_CASES)
def test_reply_com_memoria_relacionada_ganha_o_prefixo(locale, brand, text, category, topic):
    plain = decide(text, brand=brand, locale=locale)
    entry = memory_entry(category=category, resolved_at="2026-11-10T23:30:00.000Z")

    result = decide_with_memory(text, brand, locale, entry)

    date = "10/11/2026" if locale == "pt-BR" else "11/10/2026"
    prefix = decision.MEMORY_PREFIX[locale].format(assunto=topic, data=date)
    assert plain.type == result.type == "reply"
    assert result.fields["text"] == prefix + plain.fields["text"]


def test_prefixo_usa_a_conversa_mais_recente():
    older = memory_entry(category="repasse", resolved_at="2026-11-01T10:00:00.000Z")
    newer = memory_entry(category="repasse", resolved_at="2026-11-12T10:00:00.000Z")

    result = decide_with_memory("Quando cai o repasse?", "infinitepay", "pt-BR", newer, older)

    assert result.fields["text"].startswith("Vi que você já falou com a gente sobre repasse em 12/11/2026. ")


@pytest.mark.parametrize("text, expected_type", [
    ("Oi, tudo bem? Preciso de ajuda.", "reply"),
    ("Obrigado, deu tudo certo!", "resolve"),
    ("Quero mudar o endereço cadastrado.", "escalate"),
])
def test_saudacao_resolve_e_escalate_nao_mudam(text, expected_type):
    entry = memory_entry(category="repasse", resolved_at="2026-11-12T10:00:00.000Z")

    result = decide_with_memory(text, "infinitepay", "pt-BR", entry)

    assert result == decide(text)
    assert result.type == expected_type


def test_escalate_da_intencao_com_memoria_nao_muda():
    serial = find("SN", 8, tools.status_maquininha, "defeito")
    text = f"Preciso trocar a maquininha {serial}."
    entry = memory_entry(category="maquininha", resolved_at="2026-11-12T10:00:00.000Z")

    assert decide_with_memory(text, "infinitepay", "pt-BR", entry) == decide(text)


def test_sem_prefixo_com_memoria_sem_relacao_ou_fora_da_janela():
    text = "Quando cai o repasse?"
    plain = decide(text)

    assert decide_with_memory(text, "infinitepay", "pt-BR", memory_entry(category="taxas")) == plain
    assert decide_with_memory(text, "infinitepay", "pt-BR", memory_entry(resolved_at="2026-10-01T10:00:00.000Z")) == plain
    assert decide_with_memory(text, "infinitepay", "pt-BR", memory_entry(resolved_at="2026-11-01T10:00:00.000Z"),
                              window=5) == plain


def test_mesma_entrada_com_memoria_mesma_acao():
    entry = memory_entry(category="repasse", resolved_at="2026-11-12T10:00:00.000Z")

    results = [decide_with_memory("Quando cai o repasse?", "infinitepay", "pt-BR", entry) for _ in range(3)]

    assert results[0].fields == results[1].fields == results[2].fields

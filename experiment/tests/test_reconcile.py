import pandas as pd
from helpers import BASE, action, delivery, event, message, received, sent_frame, table

from cloudesk_experiment import reconcile


def run(sent, messages=(), actions=(), events=(), deliveries=(), received_rows=(), **options):
    frame = pd.DataFrame(list(received_rows), columns=["channel", "core_message_id", "received_at"])
    return reconcile.summary(sent_frame(*sent), table("customer_messages", *messages), table("actions", *actions),
                             table("events", *events), table("deliveries", *deliveries), frame, BASE, **options)


def categories(result):
    return {name: count for name, count in result["categories"].items() if count}


def test_atendida_por_cada_acao_aceita():
    for name in ("agent.reply", "agent.resolve", "agent.categorize", "agent.escalate"):
        result = run([{"external_id": "a"}], [message("a")], [action("a", name=name)])
        assert categories(result) == {"atendida": 1}
        assert result["ok"]


def test_atendida_por_acao_de_mensagem_mais_nova():
    result = run([{"external_id": "a"}, {"external_id": "b"}], [message("a"), message("b", sequence=2)], [action("b", sequence=2)])

    assert categories(result) == {"atendida": 2}


def test_recusada_indefinida_e_aceita_sem_message():
    result = run([{"external_id": "a", "status": 429}, {"external_id": "b", "status": 0}, {"external_id": "c"}])

    assert categories(result) == {"recusada": 1, "indefinida": 1, "aceita_sem_message": 1}
    assert result["lost"] == 1


def test_status_0_com_message_e_decidida_pela_cobertura():
    result = run([{"external_id": "a", "status": 0}], [message("a")], [action("a")])

    assert categories(result) == {"atendida": 1}
    assert result["status_0_with_message"] == 1


def test_erro_com_message_e_decidida_pela_cobertura():
    assert categories(run([{"external_id": "a", "status": 502}], [message("a")])) == {"sem_acao": 1}


def test_ai_timeout_conta_como_perdida():
    result = run([{"external_id": "a"}], [message("a", received=0)],
                 events=[event(name="conversation.escalated", reason="ai_timeout", created=60)])

    assert categories(result) == {"ai_timeout": 1}
    assert result["lost"] == 1
    assert not result["ok"]


def test_ai_timeout_anterior_a_mensagem_nao_vale():
    result = run([{"external_id": "a"}], [message("a", received=60)],
                 events=[event(name="conversation.escalated", reason="ai_timeout", created=10)])

    assert categories(result) == {"sem_acao": 1}


def test_acao_stale_e_rejected_nao_cobrem():
    result = run([{"external_id": "a"}], [message("a")],
                 [action("a", name="agent.action.stale"), action("a", name="agent.action.rejected")])

    assert categories(result) == {"sem_acao": 1}
    assert (result["stale_actions"], result["rejected_actions"]) == (1, 1)
    assert result["lost"] == 1


def test_acao_de_sequencia_menor_nao_cobre():
    assert categories(run([{"external_id": "b"}], [message("b", sequence=3)], [action("a", sequence=1)])) == {"sem_acao": 1}


def test_duplicada_por_core_message_id():
    result = run([{"external_id": "a"}], [message("a")], [action("a")], deliveries=[delivery("r1")],
                 received_rows=[received("r1", 1), received("r1", 2), received("r2", 3)])

    assert result["duplicated"] == 1
    assert result["duplicated_core_message_ids"] == ["r1"]
    assert not result["ok"]


def test_duplicada_anterior_ao_inicio_da_carga_nao_conta():
    result = run([{"external_id": "a"}], [message("a")], [action("a")], received_rows=[received("r0", -9), received("r0", -8)])

    assert result["duplicated"] == 0


def test_entrega_sem_registro_nao_e_perda():
    result = run([{"external_id": "a"}], [message("a", channel="chat")], [action("a")],
                 deliveries=[delivery("r1", channel="chat"), delivery("antiga", "outra")])

    assert result["deliveries_without_record"] == {"chat": 1}
    assert result["ok"]


def test_email_separa_a_fila_humana():
    result = run([{"external_id": "a", "status": 250}, {"external_id": "b", "status": 250}],
                 [message("a"), message("b", "c2")], [action("a")],
                 events=[event(), event("c2", first_attendant="human")], accepted_status=250, human_queue=True)

    assert categories(result) == {"atendida": 1, "fila_humana": 1}
    assert result["ok"]

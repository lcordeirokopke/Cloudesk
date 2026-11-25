"""Reconciliação: o que aconteceu com cada mensagem enviada.

| Categoria | Regra |
| - | - |
| recusada | Status diferente de 200 e de 0, sem Message no Core |
| indefinida | Status 0 (sem resposta), sem Message no Core |
| aceita_sem_message | Status 200 sem Message no Core |
| atendida | Ação aceita da conversa com based_on_sequence maior ou igual à sequence |
| ai_timeout | Sem cobertura, com escalação ai_timeout da conversa depois da mensagem |
| sem_acao | Com Message, sem nenhuma das anteriores |
| fila_humana | Só no e-mail: conversa roteada à fila humana |

A mensagem com Message no Core é classificada pela cobertura, qualquer que seja o status. Perdidas:
aceita_sem_message, sem_acao e ai_timeout. Duplicadas: core_message_id repetido nas respostas
recebidas pelo simulador desde o início da carga.
"""

import pandas as pd

from .latency import covered_up_to, timestamps

CATEGORIES = ("atendida", "recusada", "indefinida", "aceita_sem_message", "sem_acao", "ai_timeout", "fila_humana")
LOST = ("aceita_sem_message", "sem_acao", "ai_timeout")
AI_TIMEOUT = "ai_timeout"


def classify(sent: pd.DataFrame, messages: pd.DataFrame, actions: pd.DataFrame, events: pd.DataFrame,
             accepted_status: int = 200, human_queue: bool = False) -> pd.DataFrame:
    """sent com as colunas category e has_message. human_queue: considera a fila humana (e-mail)."""
    unique = messages.drop_duplicates("external_id")
    core = dict(zip(unique["external_id"],
                    zip(unique["conversation_id"], unique["sequence"], timestamps(unique["created_at"]))))
    coverage = covered_up_to(actions)
    escalated = events[(events["action"] == "conversation.escalated") & (events["reason"] == AI_TIMEOUT)]
    timeouts = timestamps(escalated["created_at"]).groupby(escalated["conversation_id"]).max().to_dict()
    routed = events[events["action"] == "conversation.routed"]
    human = set(routed.loc[routed["first_attendant"] == "human", "conversation_id"]) if human_queue else set()

    def category(external_id, status) -> str:
        if external_id not in core:
            if status == accepted_status:
                return "aceita_sem_message"
            return "indefinida" if status == 0 else "recusada"
        conversation, sequence, created = core[external_id]
        if coverage.get(conversation, 0) >= sequence:
            return "atendida"
        if conversation in timeouts and timeouts[conversation] >= created:
            return "ai_timeout"
        return "fila_humana" if conversation in human else "sem_acao"

    result = sent.copy()
    result["has_message"] = result["external_id"].isin(list(core))
    result["category"] = [category(*pair) for pair in zip(result["external_id"], result["status"])]
    return result


def counts(classified: pd.DataFrame) -> dict[str, int]:
    found = classified["category"].value_counts()
    return {name: int(found.get(name, 0)) for name in CATEGORIES}


def duplicates(received: pd.DataFrame, start) -> list[str]:
    """core_message_id recebidos mais de uma vez, com alguma entrega a partir de start."""
    if received.empty:
        return []
    frame = received.dropna(subset=["core_message_id"])
    repeated = frame[frame.duplicated("core_message_id", keep=False)]
    recent = timestamps(repeated["received_at"]) >= pd.Timestamp(start)
    return sorted(set(repeated.loc[recent, "core_message_id"]))


def without_record(messages: pd.DataFrame, deliveries: pd.DataFrame, received: pd.DataFrame) -> dict[str, int]:
    """Entregas da etapa sem registro no simulador, por canal. Não são perda."""
    replied = deliveries.dropna(subset=["in_reply_to_sequence"])
    if replied.empty or messages.empty:
        return {}
    keys = set(zip(messages["conversation_id"], messages["sequence"].astype(int)))
    in_stage = [key in keys for key in zip(replied["conversation_id"], replied["in_reply_to_sequence"].astype(int))]
    known = set(received["core_message_id"]) if len(received) else set()
    stage = replied[in_stage]
    missing = stage[~stage["message_id"].isin(known)].drop_duplicates("message_id")
    return {channel: int(count) for channel, count in missing["channel"].value_counts().items()}


def summary(sent: pd.DataFrame, messages: pd.DataFrame, actions: pd.DataFrame, events: pd.DataFrame,
            deliveries: pd.DataFrame, received: pd.DataFrame, start, **options) -> dict:
    """messages: mensagens da etapa no Core; actions: ações das conversas da etapa; start: início da carga."""
    classified = classify(sent, messages, actions, events, **options)
    by_category = counts(classified)
    lost = sum(by_category[name] for name in LOST)
    repeated = duplicates(received, start)
    inbound = set(messages["event_id"])
    stage_actions = actions[actions["inbound_event_id"].isin(inbound)]
    return {
        "sent": len(sent),
        "categories": by_category,
        "status_0_with_message": int(((classified["status"] == 0) & classified["has_message"]).sum()),
        "lost": lost,
        "duplicated": len(repeated),
        "duplicated_core_message_ids": repeated[:20],
        "deliveries_without_record": without_record(messages, deliveries, received),
        "stale_actions": int((stage_actions["action"] == "agent.action.stale").sum()),
        "rejected_actions": int((stage_actions["action"] == "agent.action.rejected").sum()),
        "ok": lost == 0 and not repeated,
    }

module Conversations
  # "Por que caiu aqui?": explica, a partir de audit_events, como a conversa chegou à fila atual.
  # Roda dentro do Tenancy.with_brand da marca da conversa e lê o último evento de cada tipo:
  #   routed:     conversation.routed, com a regra e a versão que casaram, fila, prioridade, SLA,
  #               atendente inicial, transbordo e a cadeia de filas visitadas;
  #   classified: conversation.classified, com categoria, urgência, palavras encontradas,
  #               pontuação e versão das listas do classificador;
  #   escalated:  conversation.escalated, com a fila de origem e a de destino.
  # Cada parte é nil quando a conversa não tem o evento.
  module RoutingExplanation
    Explanation = Data.define(:routed, :classified, :escalated)

    module_function

    def for(conversation)
      Explanation.new(
        routed: routed(last(conversation, "conversation.routed")),
        classified: classified(last(conversation, "conversation.classified")),
        escalated: escalated(last(conversation, "conversation.escalated"))
      )
    end

    def last(conversation, action)
      AuditEvent.where(conversation_id: conversation.id, action: action).order(created_at: :desc, id: :desc).first
    end

    def routed(event)
      return nil if event.nil?

      payload = event.payload.fetch("payload", {})
      rule = payload.fetch("rule", {})
      {
        at: event.created_at, trigger: payload["trigger"], rule_name: rule["name"], rule_id: rule["rule_id"],
        rule_version: event.rule_version, queue: payload["queue"], priority: payload["priority"],
        sla_minutes: payload["sla_minutes"], first_attendant: payload["first_attendant"],
        overflow: payload["overflow"], queue_chain: payload.fetch("queue_chain", [])
      }
    end

    def classified(event)
      return nil if event.nil?

      payload = event.payload.fetch("payload", {})
      {
        at: event.created_at, trigger: payload["trigger"], actor_type: event.actor_type,
        category: payload["category"], urgency: payload["urgency"], matches: payload.fetch("matches", {}),
        scores: payload.fetch("scores", {}), classifier_version: payload["classifier_version"]
      }
    end

    def escalated(event)
      return nil if event.nil?

      payload = event.payload.fetch("payload", {})
      {
        at: event.created_at, actor_type: event.actor_type, reason: event.reason, from_queue: payload["from_queue"],
        to_queue: payload["to_queue"], moved: payload["moved"]
      }
    end
  end
end

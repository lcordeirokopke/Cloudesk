module Conversations
  # Escalação de uma conversa para a fila humana, chamada pelo escalate do agente
  # (Agents::ActionProcessor) e pela varredura do timeout (Conversations::AiTimeoutSweepJob). Roda
  # dentro do Tenancy.with_brand de quem chama, com a conversa já travada:
  #   1. destino: a escalation_queue da fila atual ou, sem ela, a própria fila atual;
  #   2. conta as conversas abertas do destino, sem trava; a contagem e a capacidade do destino vão
  #      para o audit_event, e a escalação não confere a capacidade;
  #   3. conversation.escalated, com atualização do painel do analista: cria o Handoff e leva a
  #      conversa a awaiting_human no destino, sem atendente e com queued_at. A prioridade fica a
  #      mesma; ao mudar de fila, a conversa recebe o SLA do destino.
  # Devolve o Handoff.
  module Escalate
    module_function

    # reason, summary, context: motivo, resumo e contexto estruturado do Handoff; reason também é o
    #                           motivo do audit_event.
    # actor_type, actor_id:     quem escalou (ai, com o atendente da conversa, ou system).
    def call(conversation:, reason:, summary:, context:, actor_type:, actor_id: nil)
      if Tenancy.current_brand_id != conversation.brand_id.to_s
        raise ArgumentError, "Conversations::Escalate roda dentro do Tenancy.with_brand da marca da conversa"
      end

      brand = Brand.find(conversation.brand_id)
      origin = conversation.queue
      destination = origin&.escalation_queue || origin
      moved = destination.present? && destination.id != origin&.id
      open_conversations = destination && Conversation.where(queue_id: destination.id, state: Conversation::OPEN_STATES).count

      Audit::Command.call(brand: brand, type: "conversation.escalated", actor_type: actor_type, actor_id: actor_id,
                          reason: reason, panel: true) do |change|
        change.before = snapshot(conversation)
        handoff = Handoff.create!(conversation: conversation, reason: reason, summary: summary, context: context)
        attributes = { state: "awaiting_human", attendant_id: nil, queued_at: Current.received_at || Time.current }
        attributes.merge!(queue_id: destination.id, sla_minutes: destination.sla_minutes) if moved
        conversation.update!(attributes)
        change.after = snapshot(conversation)
        change.target = conversation
        change.conversation = conversation
        change.payload = {
          handoff_id: handoff.id, from_queue: origin&.name, to_queue: destination&.name, moved: moved,
          open_conversations: open_conversations, capacity: destination&.capacity
        }
        handoff
      end.value
    end

    def snapshot(conversation)
      {
        state: conversation.state, queue_id: conversation.queue_id, attendant_id: conversation.attendant_id,
        sla_minutes: conversation.sla_minutes, queued_at: conversation.queued_at&.utc&.iso8601(3)
      }
    end
  end
end

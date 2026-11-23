module Conversations
  # Linha do tempo de uma mensagem do lojista, montada a partir de audit_events e do trace_id do
  # message.created dela. Roda dentro do Tenancy.with_brand de quem chama e só lê.
  #
  #   events: todos os audit_events com o trace_id do message.created, por created_at e id.
  #   steps:  os saltos, em ordem, com o horário de cada um:
  #     1. Canal → Core: received_at do message.created (detalhe: canal);
  #     2. Core → Broker: broker_received_at;
  #     3. Kafka: kafka_appended_at;
  #     4. Agente consumiu: agent_consumed_at;
  #     5. uma linha por ferramenta, no started_at (detail: o finished_at, um Time);
  #     6. Agente publicou: agent_published_at (detalhe: latência artificial, quando há model);
  #     7. Broker → Core: received_at de cada ação do agente sobre a mensagem, aceita (agent.<tipo>)
  #        ou recusada (agent.action.stale, agent.action.rejected);
  #     8. Cliente: delivered_at da primeira entrega da resposta ai à mensagem (in_reply_to_sequence).
  # Os carimbos dos passos 2 a 6 vêm da primeira ação cujo inbound_event_id é o event_id do
  # message.created. Sem ação, os passos param no 1.
  module MessageTimeline
    Timeline = Data.define(:message, :steps, :events) do
      # trace_id do message.created, que está sempre em events.
      def trace_id
        events.first&.trace_id
      end

      # true quando nenhuma ação do agente cobre a mensagem: os passos param no 1.
      def without_action?
        steps.size == 1
      end
    end
    Step = Data.define(:label, :at, :detail)

    ACTION_EVENTS = %w[agent.reply agent.escalate agent.categorize agent.resolve agent.action.stale agent.action.rejected].freeze

    module_function

    def for(message)
      created = AuditEvent.find_by!(action: "message.created", target_type: "Message", target_id: message.id,
                                    conversation_id: message.conversation_id)
      events = AuditEvent.where(trace_id: created.trace_id).order(:created_at, :id).to_a
      actions = events.select do |event|
        ACTION_EVENTS.include?(event.action) && event.payload.dig("payload", "action", "inbound_event_id") == created.event_id
      end

      steps = [ Step.new(label: "Canal → Core", at: time(created.payload["received_at"]), detail: message.channel) ]
      steps += agent_steps(actions, message) if actions.any?

      Timeline.new(message: message, steps: steps, events: events)
    end

    def agent_steps(actions, message)
      action = actions.first.payload.dig("payload", "action")
      stamps = action.fetch("timestamps")
      artificial_ms = action.dig("model", "parameters", "artificial_latency_ms")

      steps = [
        Step.new(label: "Core → Broker", at: time(stamps["broker_received_at"]), detail: nil),
        Step.new(label: "Kafka", at: time(stamps["kafka_appended_at"]), detail: nil),
        Step.new(label: "Agente consumiu", at: time(stamps["agent_consumed_at"]), detail: nil)
      ]
      steps += Array(action["tools"]).map do |tool|
        Step.new(label: "Ferramenta #{tool['name']}", at: time(tool["started_at"]), detail: time(tool["finished_at"]))
      end
      steps << Step.new(label: "Agente publicou", at: time(stamps["agent_published_at"]),
                        detail: artificial_ms.nil? ? nil : "latência artificial #{artificial_ms} ms")
      steps += actions.map do |event|
        Step.new(label: "Broker → Core", at: time(event.payload["received_at"]), detail: action_detail(event))
      end

      delivered_at = delivered_at(message)
      steps << Step.new(label: "Cliente", at: delivered_at, detail: nil) if delivered_at
      steps
    end

    def action_detail(event)
      case event.action
      when "agent.action.stale" then "recusada: stale (#{event.payload.dig('payload', 'action', 'type')})"
      when "agent.action.rejected" then "recusada: rejected (#{event.payload.dig('payload', 'action', 'type')})"
      else event.action.delete_prefix("agent.")
      end
    end

    # delivered_at da primeira entrega da resposta da IA cuja mensagem respondida é a do lojista.
    def delivered_at(message)
      replies = AuditEvent.where(action: "message.created", target_type: "Message", actor_type: "ai",
                                 conversation_id: message.conversation_id)
                          .where("payload -> 'payload' ->> 'in_reply_to_sequence' = ?", message.sequence.to_s)
                          .pluck(:target_id)
      return nil if replies.empty?

      delivered = AuditEvent.where(action: "message.delivered", conversation_id: message.conversation_id, target_id: replies)
                            .order(:id).first
      delivered && time(delivered.payload.dig("payload", "delivered_at"))
    end

    def time(value)
      value && Time.iso8601(value)
    end
  end
end

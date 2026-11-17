module Contract
  # Idempotency-Key de uma ação do agente: "<inbound_event_id>:<type>".
  # Deriva do event_id do evento de entrada e do tipo da ação; um evento reentregue ao agente produz
  # a mesma chave. O Broker a calcula a partir do corpo da ação e a envia no header à API de ações.
  module IdempotencyKey
    HEADER = "Idempotency-Key".freeze
    ACTION_TYPES = %w[reply escalate categorize resolve].freeze

    class << self
      def derive(inbound_event_id:, type:)
        raise ArgumentError, "inbound_event_id não informado" if inbound_event_id.to_s.empty?
        raise ArgumentError, "tipo de ação desconhecido: #{type.inspect}" unless ACTION_TYPES.include?(type.to_s)

        "#{inbound_event_id}:#{type}"
      end

      # Chave da ação, a partir do corpo dela.
      def for_action(action)
        action = action.transform_keys(&:to_s)
        derive(inbound_event_id: action["inbound_event_id"], type: action["type"])
      end
    end
  end
end

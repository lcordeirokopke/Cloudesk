module Contract
  # Corpo do webhook message.created, montado a partir do envelope canônico do evento
  # (Audit::EventEnvelope#to_h). O conteúdo de payload sobe para o nível raiz, e a context_url
  # aponta para o contexto da conversa no Core.
  module MessageCreated
    TYPE = "message.created".freeze
    SCHEMA = "webhook.message-created".freeze

    class << self
      def context_url(conversation_id)
        "/api/v1/agent/conversations/#{conversation_id}/context"
      end

      def build(envelope)
        envelope = envelope.transform_keys(&:to_s)
        raise ArgumentError, "o evento não é #{TYPE}" unless envelope["type"] == TYPE

        body = {
          "event_id" => envelope["event_id"],
          "type" => TYPE,
          "brand" => envelope["brand"],
          "conversation_id" => envelope["conversation_id"],
          "sequence" => envelope["sequence"],
          "received_at" => envelope["received_at"],
          "message" => envelope.fetch("payload").fetch("message"),
          "context_url" => context_url(envelope["conversation_id"]),
          "traceparent" => envelope["traceparent"]
        }
        Schemas.validate!(SCHEMA, body)
      end
    end
  end
end

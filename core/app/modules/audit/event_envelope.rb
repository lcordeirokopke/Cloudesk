module Audit
  # Envelope canônico de evento: o formato único de todo evento do Core, qualquer que seja a origem.
  # É gravado inteiro em audit_events.payload, e o event_id é o mesmo da coluna audit_events.event_id.
  #   event_id:        UUID v7 do evento.
  #   type:            tipo do evento, por exemplo "message.created".
  #   brand:           slug da marca.
  #   conversation_id: conversa do evento, ou nil quando o evento não pertence a uma conversa.
  #   sequence:        sequência da mensagem na conversa, ou nil quando o evento não é de mensagem.
  #   received_at:     horário em que o Core recebeu a requisição que produziu o evento.
  #   payload:         conteúdo completo do evento, específico do tipo.
  #   traceparent:     contexto de trace W3C do salto que produziu o evento.
  EventEnvelope = Data.define(
    :event_id, :type, :brand, :conversation_id, :sequence, :received_at, :payload, :traceparent
  ) do
    def self.build(type:, brand:, received_at:, traceparent:, conversation_id: nil, sequence: nil, payload: {},
                   event_id: SecureRandom.uuid_v7)
      raise ArgumentError, "type não informado" if type.blank?
      raise ArgumentError, "brand não informada" if brand.blank?
      raise ArgumentError, "received_at não informado" if received_at.nil?
      raise ArgumentError, "traceparent inválido" unless traceparent.is_a?(TraceContext::Traceparent)

      new(
        event_id: event_id,
        type: type.to_s,
        brand: brand.to_s,
        conversation_id: conversation_id,
        sequence: sequence,
        received_at: received_at.utc,
        payload: payload.as_json,
        traceparent: traceparent
      )
    end

    # Lê o envelope gravado em audit_events.payload.
    def self.from_h(hash)
      hash = hash.with_indifferent_access
      build(
        event_id: hash.fetch(:event_id),
        type: hash.fetch(:type),
        brand: hash.fetch(:brand),
        conversation_id: hash[:conversation_id],
        sequence: hash[:sequence],
        received_at: Time.iso8601(hash.fetch(:received_at)),
        payload: hash[:payload] || {},
        traceparent: TraceContext.parse(hash.fetch(:traceparent))
      )
    end

    def trace_id
      traceparent.trace_id
    end

    # Forma serializável em JSON; received_at em ISO 8601, UTC, com milissegundos.
    def to_h
      {
        "event_id" => event_id,
        "type" => type,
        "brand" => brand,
        "conversation_id" => conversation_id,
        "sequence" => sequence,
        "received_at" => received_at.iso8601(3),
        "payload" => payload,
        "traceparent" => traceparent.to_s
      }
    end
  end
end

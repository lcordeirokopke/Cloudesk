module Broker
  # Publicação em agent.dlq pelo produtor do próprio broker-consumer: mesma chave, mesmo payload e
  # headers originais, mais os headers de diagnóstico (schema kafka.dlq-headers). O produce_sync
  # lança quando o Kafka não confirma, e o consumidor reprocessa a mensagem.
  #
  # Motivos (dlq_reason):
  #   invalid_message    valor ilegível ou sem os campos da Idempotency-Key; o Core não é chamado
  #   core_rejected      o Core recusou a ação com status final diferente de 200 e 409
  #   retries_exhausted  falha transitória na última tentativa
  module DeadLetter
    SCHEMA = "kafka.dlq-headers".freeze
    REASONS = %w[invalid_message core_rejected retries_exhausted].freeze

    module_function

    def publish(producer:, message:, reason:, status: nil, now: Time.now)
      producer.produce_sync({
        topic: DLQ_TOPIC,
        payload: message.raw_payload,
        key: message.raw_key,
        headers: headers(message, reason: reason, status: status, now: now)
      }.compact)
    end

    def headers(message, reason:, status:, now:)
      diagnostics = {
        "dlq_reason" => reason,
        "dlq_status" => status&.to_s,
        "dlq_source_topic" => message.topic,
        "dlq_source_partition" => message.partition.to_s,
        "dlq_source_offset" => message.offset.to_s,
        "dlq_failed_at" => now.utc.iso8601(3)
      }.compact
      Contract::Schemas.validate!(SCHEMA, diagnostics)

      (message.raw_headers || {}).merge(diagnostics)
    end
  end
end

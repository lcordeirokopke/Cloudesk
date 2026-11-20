module Broker
  # Consumidor de agent.outbound (broker-consumer). Para cada ação, deriva a Idempotency-Key, chama a
  # API de ações do Core e marca a mensagem como consumida só depois do resultado final:
  #
  #   200 e 409                 final; marca e segue
  #   demais recusas do Core    DLQ; marca e segue
  #   valor ilegível            DLQ sem chamar o Core; marca e segue
  #   falha transitória         lança: o Karafka pausa a partição e reprocessa a partir desta
  #                             mensagem, com backoff exponencial (karafka.rb); na tentativa
  #                             MAX_ATTEMPTS, publica na DLQ e marca
  #
  # O schema da ação é conferido pelo Core. Se a publicação na DLQ falha, o consumidor lança e a
  # mensagem entra no mesmo retry.
  class ActionsConsumer < Karafka::BaseConsumer
    MAX_ATTEMPTS = 10

    def consume
      messages.each do |message|
        process(message)
        # false quando a partição foi perdida para outro consumidor do grupo: o restante do lote
        # fica com ele.
        return unless mark_as_consumed(message)
      end
    end

    private

    def process(message)
      idempotency_key = idempotency_key(message)
      return dead_letter(message, reason: "invalid_message") if idempotency_key.nil?

      result = CoreClient.deliver(
        body: message.raw_payload, idempotency_key: idempotency_key,
        traceparent: TraceContext.continue(header(message, "traceparent")).to_s
      )
      return if result.final?

      Karafka.logger.warn("ação recusada pelo Core com #{result.status} (#{location(message)}): #{result.body[0, 500]}")
      dead_letter(message, reason: "core_rejected", status: result.status)
    rescue TransientError => failure
      Karafka.logger.warn("tentativa #{attempt} de #{MAX_ATTEMPTS} (#{location(message)}): #{failure.message}")
      raise if attempt < MAX_ATTEMPTS

      dead_letter(message, reason: "retries_exhausted", status: failure.status)
    end

    # Idempotency-Key da ação, ou nil quando o valor não é um objeto JSON com inbound_event_id e um
    # tipo de ação conhecido.
    def idempotency_key(message)
      action = JSON.parse(message.raw_payload.to_s)
      return nil unless action.is_a?(Hash)

      Contract::IdempotencyKey.for_action(action)
    rescue JSON::ParserError, ArgumentError
      nil
    end

    def header(message, name)
      value = (message.raw_headers || {})[name]
      value.is_a?(Array) ? value.last : value
    end

    def dead_letter(message, reason:, status: nil)
      DeadLetter.publish(producer: producer, message: message, reason: reason, status: status)
      Karafka.logger.warn("ação publicada em #{DLQ_TOPIC} por #{reason} (#{location(message)})")
    end

    def location(message)
      "#{message.topic}/#{message.partition}@#{message.offset}"
    end
  end
end

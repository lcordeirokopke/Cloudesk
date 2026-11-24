module Admin
  # Reprocessamento de uma mensagem de agent.dlq pela tela /admin/dlq, uma por vez:
  #   1. acha a mensagem na listagem da marca no Broker (Admin::DlqClient#list), o mesmo conjunto que
  #      a tela mostra;
  #   2. confere o alvo (blocked_reason): a mensagem é da marca, o dlq_reason não é invalid_message e
  #      a chave Kafka é o id de uma conversa da marca. Sem isso, Admin::NotAllowed, sem chamar o
  #      Broker;
  #   3. pede a republicação ao Broker (Admin::DlqClient#reprocess), fora de transação;
  #   4. com o 200, grava dlq.reprocessed pelo Audit::Command, ator operator, alvo e conversa a
  #      conversa da chave, com origem, destino, diagnóstico e operator_name.
  # Falha no Broker: nada é gravado, e o Admin::DlqClient::Error sobe. Falha na gravação depois do
  # 200: a mensagem já está em agent.outbound; o erro vai ao log com origem e destino e sobe.
  # A mesma mensagem pode ser reprocessada de novo: cada republicação grava um evento, e o Core
  # deduplica a ação pela Idempotency-Key (processed_events).
  # Devolve o resultado do Audit::Command (value: a resposta do Broker).
  module DlqReprocessor
    EVENT = "dlq.reprocessed".freeze
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def call(brand:, partition:, offset:, operator_name:)
      message = DlqClient.list(brand: brand).find do |item|
        item["partition"] == Integer(partition) && item["offset"] == Integer(offset)
      end
      raise NotAllowed, "a mensagem #{partition}@#{offset} não está na listagem da DLQ da marca" if message.nil?

      reason = blocked_reasons(brand: brand, messages: [ message ]).values.first
      raise NotAllowed, reason if reason

      result = DlqClient.reprocess(brand: brand, partition: message["partition"], offset: message["offset"])
      record(brand, message, result, operator_name)
    end

    # Motivo do bloqueio de cada mensagem, por [partition, offset]; nil quando ela pode ser
    # reprocessada.
    def blocked_reasons(brand:, messages:)
      keys = messages.map { |message| message["key"].to_s }.select { |key| key.match?(UUID) }
      conversations = keys.empty? ? [] : Tenancy.with_brand(brand) { Conversation.where(id: keys).pluck(:id) }

      messages.to_h do |message|
        [ [ message["partition"], message["offset"] ], blocked_reason(brand, message, conversations) ]
      end
    end

    def blocked_reason(brand, message, conversations)
      headers = message["headers"] || {}
      return "mensagem sem a marca no header brand" if headers["brand"].to_s.empty?
      return "mensagem da marca #{headers['brand']}" if headers["brand"] != brand.slug
      return "valor ilegível ou sem os campos da Idempotency-Key (invalid_message)" if headers["dlq_reason"] == "invalid_message"
      return "a chave #{message['key'].inspect} não é uma conversa da marca" unless conversations.include?(message["key"].to_s)

      nil
    end

    def record(brand, message, result, operator_name)
      Audit::Command.call(brand: brand, type: EVENT, actor_type: "operator") do |change|
        conversation = Conversation.find(message["key"])
        diagnostics = result.fetch("diagnostics", {})
        change.target = conversation
        change.conversation = conversation
        change.payload = {
          source: result.fetch("source"), destination: result.fetch("destination"),
          dlq_reason: diagnostics["dlq_reason"], dlq_status: diagnostics["dlq_status"],
          dlq_failed_at: diagnostics["dlq_failed_at"], operator_name: operator_name
        }
        result
      end
    rescue StandardError => error
      Rails.logger.error("#{EVENT} sem gravação depois da republicação: origem #{result['source'].to_json}, " \
                         "destino #{result['destination'].to_json}: #{error.class}: #{error.message}")
      raise
    end
  end
end

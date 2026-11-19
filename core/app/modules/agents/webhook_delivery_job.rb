module Agents
  # Job de saída do evento message.created do Core para o Broker, na fila webhooks.
  # É enfileirado por Audit::Command na mesma transação da mudança de estado e do audit_event
  # (outbox implícito); por isso enqueue_after_transaction_commit fica desligado.
  # Os argumentos levam a marca, o event_id e o traceparent; o envelope é lido de audit_events.
  #
  # Na marca do job, lê o evento e a conversa:
  #   - evento que não é message.created: WebhookError::Permanent;
  #   - conversa fora de with_ai: grava webhook.skipped e não chama o Broker;
  #   - conversa em with_ai: monta o corpo pelo contrato (Contract::MessageCreated) e o envia pelo
  #     Agents::BrokerClient, fora da transação.
  # Erro transitório tenta de novo com backoff exponencial e jitter; ao esgotar as tentativas, ou em
  # erro permanente, o job fica na fila de falhas do Solid Queue e é reprocessado pelo Mission Control.
  class WebhookDeliveryJob < ApplicationJob
    queue_as :webhooks

    self.enqueue_after_transaction_commit = false

    MAX_ATTEMPTS = 10

    retry_on WebhookError::Transient, wait: EXPONENTIAL_BACKOFF, attempts: MAX_ATTEMPTS

    def perform(brand_id:, event_id:, traceparent:)
      Current.traceparent = TraceContext.continue(traceparent)
      brand = Brand.find(brand_id)
      body = Tenancy.with_brand(brand) { prepare(brand, event_id) }
      return if body.nil?

      BrokerClient.deliver(body: body, traceparent: Current.traceparent.to_s)
    end

    private

    # Corpo JSON do webhook, ou nil quando a conversa não está em with_ai.
    def prepare(brand, event_id)
      event = AuditEvent.find_by!(event_id: event_id)
      envelope = Audit::EventEnvelope.from_h(event.payload)
      unless envelope.type == Contract::MessageCreated::TYPE
        raise WebhookError::Permanent, "o evento #{event_id} é #{envelope.type}, não #{Contract::MessageCreated::TYPE}"
      end

      conversation = Conversation.find(envelope.conversation_id)
      unless conversation.state == "with_ai"
        record_skipped(brand, event, conversation)
        return nil
      end

      Contract::MessageCreated.build(envelope.to_h).to_json
    rescue Contract::Schemas::InvalidPayload, KeyError => error
      raise WebhookError::Permanent, "o evento #{event_id} não segue o contrato: #{error.message}"
    end

    def record_skipped(brand, event, conversation)
      Audit::Command.call(brand: brand, type: "webhook.skipped", actor_type: "system",
                          reason: "conversa em #{conversation.state}") do |change|
        message = Message.find(event.target_id)
        change.target = message
        change.conversation = conversation
        change.sequence = message.sequence
        change.payload = { event_id: event.event_id, state: conversation.state }
        message
      end
    end
  end
end

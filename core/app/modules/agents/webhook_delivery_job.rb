module Agents
  # Job de saída de um evento do Core para o Broker, na fila webhooks.
  # É enfileirado por Audit::Command na mesma transação da mudança de estado e do audit_event
  # (outbox implícito); por isso enqueue_after_transaction_commit fica desligado.
  # Os argumentos levam a marca, o event_id e o traceparent; o envelope é lido de audit_events.
  class WebhookDeliveryJob < ApplicationJob
    queue_as :webhooks

    self.enqueue_after_transaction_commit = false

    def perform(brand_id:, event_id:, traceparent:)
      Current.traceparent = TraceContext.continue(traceparent)
      deliver(load_envelope(brand_id, event_id))
    end

    # Envelope do evento, lido na marca do job.
    def load_envelope(brand_id, event_id)
      Tenancy.with_brand(brand_id) do
        Audit::EventEnvelope.from_h(AuditEvent.find_by!(event_id: event_id).payload)
      end
    end

    private

    # O envio HTTP assinado ao Broker não existe no Core. O job falha e fica na fila de falhas do
    # Solid Queue, de onde é reprocessado.
    def deliver(_envelope)
      raise NotImplementedError, "envio do webhook ao Broker não implementado"
    end
  end
end

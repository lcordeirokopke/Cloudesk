module Agents
  # Tarefa recorrente do jobs-default: devolve à fila os jobs de webhook interrompidos pela morte do
  # processo que os executava.
  # No Solid Queue, os jobs em execução em um worker morto vão para a fila de falhas com um erro do
  # próprio Solid Queue, fora do retry_on:
  #   ProcessExitError:    o fork do worker terminou com erro e o supervisor percebeu;
  #   ProcessPrunedError:  o processo ficou sem heartbeat além de process_alive_threshold;
  #   ProcessMissingError: o job estava com um processo que não existe mais.
  # O reprocessamento é o mesmo do painel (SolidQueue::FailedExecution#retry), com um novo ciclo de
  # tentativas. As demais falhas (Broker recusou, tentativas esgotadas) ficam na fila de falhas.
  # Se o processo morreu depois do POST, o webhook sai de novo; a entrega é at-least-once e o Core
  # descarta a ação repetida pela Idempotency-Key.
  class RecoverInterruptedWebhooksJob < ApplicationJob
    queue_as :default

    PROCESS_ERRORS = %w[
      SolidQueue::Processes::ProcessExitError
      SolidQueue::Processes::ProcessPrunedError
      SolidQueue::Processes::ProcessMissingError
    ].freeze

    def perform
      recovered = 0
      SolidQueue::FailedExecution.joins(:job)
                                 .where(solid_queue_jobs: { class_name: WebhookDeliveryJob.name })
                                 .find_each do |failed|
        next unless PROCESS_ERRORS.include?(failed.exception_class)

        failed.retry
        recovered += 1
      end
      Rails.logger.info("webhooks interrompidos devolvidos à fila: #{recovered}") if recovered.positive?
      recovered
    end
  end
end

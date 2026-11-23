module Observability
  # Gauges do Solid Queue, lidos das tabelas solid_queue_* com consultas agrupadas. As tabelas
  # ficam fora do RLS: a leitura não passa por Tenancy.
  #
  #   cloudesk_solid_queue_jobs{queue,state}                 ready, scheduled e claimed por fila
  #   cloudesk_solid_queue_oldest_ready_age_seconds{queue}   agora menos o created_at do pronto mais antigo
  #   cloudesk_solid_queue_failed_jobs{class}                jobs na fila de falhas por classe
  #   cloudesk_solid_queue_failed_oldest_age_seconds{class}  agora menos o created_at da falha mais antiga
  class QueueReader
    def initialize(registry:)
      @registry = registry
    end

    def collect
      now = Time.current

      ready = SolidQueue::ReadyExecution.group(:queue_name).count
      scheduled = SolidQueue::ScheduledExecution.group(:queue_name).count
      claimed = SolidQueue::ClaimedExecution.joins(:job).group("solid_queue_jobs.queue_name").count
      @registry.replace(:cloudesk_solid_queue_jobs, jobs_by_state(ready: ready, scheduled: scheduled, claimed: claimed))

      oldest_ready = SolidQueue::ReadyExecution.group(:queue_name).minimum(:created_at)
      @registry.replace(:cloudesk_solid_queue_oldest_ready_age_seconds,
                        oldest_ready.to_h { |queue, created_at| [ { queue: queue }, age(now, created_at) ] })

      failed = SolidQueue::FailedExecution.joins(:job).group("solid_queue_jobs.class_name")
      @registry.replace(:cloudesk_solid_queue_failed_jobs, failed.count.to_h { |name, count| [ { class: name }, count ] })
      @registry.replace(:cloudesk_solid_queue_failed_oldest_age_seconds,
                        failed.minimum("solid_queue_failed_executions.created_at")
                              .to_h { |name, created_at| [ { class: name }, age(now, created_at) ] })
    end

    private

    # Toda fila vista em algum estado recebe os três estados, com 0 nos que não têm job.
    def jobs_by_state(counts)
      queues = counts.values.flat_map(&:keys).uniq
      queues.product(counts.keys).to_h do |queue, state|
        [ { queue: queue, state: state }, counts.fetch(state).fetch(queue, 0) ]
      end
    end

    def age(now, created_at)
      [ now - created_at, 0 ].max
    end
  end
end

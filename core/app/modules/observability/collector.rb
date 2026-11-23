module Observability
  # Coleta periódica do serviço metrics. Cada coleta chama os três leitores em sequência; o erro de
  # um leitor é registrado em log e em cloudesk_metrics_collect_errors_total{reader} e não impede os
  # outros. A duração de cada leitor vai para cloudesk_metrics_collect_duration_seconds{reader}.
  #
  # start abre a thread de fundo, que coleta a cada INTERVAL segundos dentro do executor do Rails
  # (autoload e devolução da conexão ao pool). GET /metrics só serializa o registro.
  class Collector
    INTERVAL = 5

    attr_reader :readers

    def initialize(registry:, logger: Rails.logger, readers: nil)
      @registry = registry
      @logger = logger
      @readers = readers || {
        "latency" => LatencyReader.new(registry: registry, logger: logger),
        "queue" => QueueReader.new(registry: registry),
        "cockpit" => CockpitReader.new(registry: registry)
      }
    end

    def collect_once
      @readers.each do |name, reader|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          reader.collect
        rescue StandardError => error
          @registry[:cloudesk_metrics_collect_errors_total].increment(labels: { reader: name })
          @logger.error("[observability] leitor #{name} falhou: #{error.class}: #{error.message}")
        ensure
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          @registry[:cloudesk_metrics_collect_duration_seconds].set(duration, labels: { reader: name })
        end
      end
    end

    def start
      Thread.new do
        Thread.current.name = "observability-collector"
        loop do
          begin
            Rails.application.executor.wrap { collect_once }
          rescue StandardError => error
            @logger.error("[observability] coleta falhou: #{error.class}: #{error.message}")
          end
          sleep INTERVAL
        end
      end
    end
  end
end

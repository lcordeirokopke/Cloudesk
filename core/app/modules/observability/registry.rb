require "prometheus/client"
require "prometheus/client/formats/text"

module Observability
  # Registro das métricas do serviço metrics, servido em GET /metrics (Observability::App). Cada
  # instância tem um Prometheus::Client::Registry próprio; o serviço cria uma no boot e os testes
  # criam a sua.
  #
  # Histogramas (Observability::LatencyReader), em segundos:
  #   cloudesk_hop_latency_seconds{hop,channel}          cada salto da resposta da IA
  #   cloudesk_end_to_end_latency_seconds{channel}       ponta a ponta menos a latência artificial
  #   cloudesk_end_to_end_raw_latency_seconds{channel}   ponta a ponta sem desconto
  # Gauges do Solid Queue (Observability::QueueReader):
  #   cloudesk_solid_queue_jobs{queue,state}             state: ready, scheduled, claimed
  #   cloudesk_solid_queue_oldest_ready_age_seconds{queue}
  #   cloudesk_solid_queue_failed_jobs{class}
  #   cloudesk_solid_queue_failed_oldest_age_seconds{class}
  # Gauges do domínio (Observability::CockpitReader):
  #   cloudesk_conversations_open{brand,queue,state}     state: with_ai, awaiting_human, with_human
  #   cloudesk_conversations_sla{brand,queue,level}      level: at_risk, breached
  #   cloudesk_conversations_resolved_24h{brand}
  #   cloudesk_conversations_resolved_by_ai_24h{brand}
  #   cloudesk_handoffs_24h{brand,reason}
  # Saúde da coleta (Observability::Collector):
  #   cloudesk_metrics_collect_duration_seconds{reader}
  #   cloudesk_metrics_collect_errors_total{reader}
  #
  # Os gauges são substituídos inteiros a cada coleta (replace): a série que não aparece na coleta
  # nova volta a 0.
  class Registry
    # Contêm as fronteiras das metas: 0,3 s entrada → Kafka e 1 s ponta a ponta.
    LATENCY_BUCKETS = [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2.5, 5, 10, 30, 60 ].freeze

    HISTOGRAMS = {
      cloudesk_hop_latency_seconds: [ "Latência de cada salto da resposta da IA", %i[hop channel] ],
      cloudesk_end_to_end_latency_seconds: [ "Latência ponta a ponta da resposta da IA, descontada a latência artificial do agente", %i[channel] ],
      cloudesk_end_to_end_raw_latency_seconds: [ "Latência ponta a ponta da resposta da IA, sem desconto", %i[channel] ]
    }.freeze

    GAUGES = {
      cloudesk_solid_queue_jobs: [ "Jobs do Solid Queue por fila e estado", %i[queue state] ],
      cloudesk_solid_queue_oldest_ready_age_seconds: [ "Idade do job pronto mais antigo, por fila", %i[queue] ],
      cloudesk_solid_queue_failed_jobs: [ "Jobs na fila de falhas do Solid Queue, por classe", %i[class] ],
      cloudesk_solid_queue_failed_oldest_age_seconds: [ "Tempo do job mais antigo na fila de falhas, por classe", %i[class] ],
      cloudesk_conversations_open: [ "Conversas abertas por marca, fila e estado", %i[brand queue state] ],
      cloudesk_conversations_sla: [ "Conversas em risco de SLA (at_risk) ou vencidas (breached)", %i[brand queue level] ],
      cloudesk_conversations_resolved_24h: [ "Conversas resolvidas nas últimas 24 h", %i[brand] ],
      cloudesk_conversations_resolved_by_ai_24h: [ "Conversas resolvidas pela IA sem handoff nas últimas 24 h", %i[brand] ],
      cloudesk_handoffs_24h: [ "Handoffs das últimas 24 h por motivo", %i[brand reason] ],
      cloudesk_metrics_collect_duration_seconds: [ "Duração da última coleta de cada leitor", %i[reader] ]
    }.freeze

    COUNTERS = {
      cloudesk_metrics_collect_errors_total: [ "Erros de coleta por leitor", %i[reader] ]
    }.freeze

    attr_reader :prometheus

    def self.build
      new
    end

    def initialize
      @prometheus = Prometheus::Client::Registry.new
      @previous_labels = Hash.new { |hash, name| hash[name] = [] }
      @lock = Mutex.new

      HISTOGRAMS.each do |name, (docstring, labels)|
        @prometheus.histogram(name, docstring: docstring, labels: labels, buckets: LATENCY_BUCKETS)
      end
      GAUGES.each { |name, (docstring, labels)| @prometheus.gauge(name, docstring: docstring, labels: labels) }
      COUNTERS.each { |name, (docstring, labels)| @prometheus.counter(name, docstring: docstring, labels: labels) }
    end

    def [](name)
      @prometheus.get(name)
    end

    # Grava o conjunto inteiro de séries de um gauge: values é { labels => valor }. As séries da
    # coleta anterior que não estão em values passam a 0 (a gem não remove séries).
    def replace(name, values)
      gauge = self[name]
      @lock.synchronize do
        current = values.keys.map { |labels| labels.transform_keys(&:to_sym).transform_values(&:to_s) }
        (@previous_labels[name] - current).each { |labels| gauge.set(0, labels: labels) }
        values.each { |labels, value| gauge.set(value, labels: labels.transform_keys(&:to_sym).transform_values(&:to_s)) }
        @previous_labels[name] = current
      end
    end

    # Valor de uma série; 0 para a série que não existe.
    def value(name, labels = {})
      self[name].get(labels: labels.transform_keys(&:to_sym).transform_values(&:to_s))
    end

    def render
      Prometheus::Client::Formats::Text.marshal(@prometheus)
    end
  end
end

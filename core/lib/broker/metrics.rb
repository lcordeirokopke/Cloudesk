module Broker
  # Métricas do broker-web, servidas em GET /metrics no formato de texto do Prometheus.
  #
  #   cloudesk_broker_inbound_latency_seconds{brand}  histograma da latência entrada → Kafka: horário
  #                                                   da confirmação do Kafka menos o received_at do
  #                                                   corpo do webhook (recebimento HTTP no Core). Só
  #                                                   nas respostas 200.
  #   cloudesk_broker_webhooks_total{status}          respostas do POST do webhook, por código HTTP.
  #
  # O broker-web é Puma single: um registro por processo, em memória, compartilhado pelas threads.
  # Com mais de uma réplica, o Prometheus coleta cada uma e soma as séries.
  class Metrics
    # Em segundos; contêm as fronteiras das metas (0,3 s entrada → Kafka e 1 s ponta a ponta).
    LATENCY_BUCKETS = [ 0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2.5, 5, 10, 30, 60 ].freeze

    attr_reader :registry, :inbound_latency, :webhooks

    # Registro do processo, usado pelo broker.ru.
    def self.default
      @default ||= new
    end

    def self.render
      default.render
    end

    def initialize
      @registry = Prometheus::Client::Registry.new
      @inbound_latency = @registry.histogram(
        :cloudesk_broker_inbound_latency_seconds,
        docstring: "Latência entrada → Kafka: confirmação do Kafka menos o received_at do Core",
        labels: [ :brand ], buckets: LATENCY_BUCKETS
      )
      @webhooks = @registry.counter(
        :cloudesk_broker_webhooks_total,
        docstring: "Respostas do webhook message.created, por código HTTP",
        labels: [ :status ]
      )
    end

    def observe_inbound_latency(brand:, seconds:)
      @inbound_latency.observe(seconds, labels: { brand: brand })
    end

    def count_webhook(status)
      @webhooks.increment(labels: { status: status.to_s })
    end

    def render
      Prometheus::Client::Formats::Text.marshal(@registry)
    end
  end
end

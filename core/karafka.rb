# Arquivo de boot do broker-consumer (bundle exec karafka server). Carrega o Broker sem Rails
# (lib/broker.rb) e consome agent.outbound no grupo cloudesk-broker.
#
# Retry das falhas transitórias pela pausa nativa do Karafka: o consume lança, a partição pausa e a
# mensagem que falhou é reprocessada depois de pause.timeout * 2^tentativa, até pause.max_timeout.
# Os offsets são marcados pelo Broker::ActionsConsumer só depois do resultado final de cada ação.
require_relative "lib/broker"

# Log sem buffer: a saída do contêiner não é um terminal.
$stdout.sync = true

class KarafkaApp < Karafka::App
  setup do |config|
    config.client_id = "cloudesk-broker-consumer"
    config.kafka = { "bootstrap.servers": Broker::Settings.kafka_brokers }
    config.initial_offset = "earliest"
    config.logger = Logger.new($stdout, level: Logger::INFO)
    config.pause.timeout = 2_000
    config.pause.max_timeout = 60_000
    config.pause.with_exponential_backoff = true
    # Produtor do próprio broker-consumer, usado na publicação em agent.dlq.
    config.producer = Broker::Producer.build(client_id: "cloudesk-broker-consumer", logger: config.logger)
  end

  routes.draw do
    consumer_group Broker::CONSUMER_GROUP do
      topic Broker::OUTBOUND_TOPIC do
        consumer Broker::ActionsConsumer
        manual_offset_management true
        initial_offset "earliest"
      end
    end
  end
end

Karafka.monitor.subscribe(Karafka::Instrumentation::LoggerListener.new)
Karafka.producer.monitor.subscribe(WaterDrop::Instrumentation::LoggerListener.new(Karafka.logger))

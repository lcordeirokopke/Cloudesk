# Apoio aos testes do Broker, sem Rails e sem banco: carrega lib/broker.rb e o karafka.rb, como os
# processos broker-web e broker-consumer. Não usa rails_helper.
require "spec_helper"

# Valores dos testes. KAFKA_BROKERS é lido no setup do Karafka, ao carregar o karafka.rb; nenhum
# teste conecta ao Kafka.
module BrokerHelpers
  ENVIRONMENT = {
    "KAFKA_BROKERS" => "kafka.test:9092",
    "CORE_ACTIONS_URL" => "http://core.test/api/v1/agent/actions",
    "BROKER_WEBHOOK_SECRET" => "broker-webhook-secret-de-teste",
    "AGENT_ACTIONS_SECRET" => "agent-actions-secret-de-teste"
  }.freeze

  def broker_env(name)
    ENVIRONMENT.fetch(name)
  end

  # Exemplo do contrato em contracts/v1/examples/<schema>/valid/<name>.json, como texto.
  def contract_example(schema, name)
    Contract::Schemas.root.join("examples", schema, "valid", "#{name}.json").read
  end
end

ENV["KAFKA_BROKERS"] ||= BrokerHelpers::ENVIRONMENT.fetch("KAFKA_BROKERS")

require_relative "../lib/broker"
require_relative "../karafka"
require "karafka/testing/rspec/helpers"
require "rack/test"
require "webmock/rspec"

WebMock.disable_net_connect!

# O log INFO do Karafka e do WaterDrop (uma linha por publicação) fica fora da saída dos testes.
Karafka.logger.level = Logger::WARN

RSpec.configure do |config|
  config.include BrokerHelpers, broker: true

  # Os valores do Broker valem só durante o teste; os do ambiente voltam ao fim de cada um.
  config.around(:each, broker: true) do |example|
    saved = BrokerHelpers::ENVIRONMENT.keys.to_h { |name| [ name, ENV[name] ] }
    ENV.update(BrokerHelpers::ENVIRONMENT)
    example.run
  ensure
    saved.each { |name, value| ENV[name] = value }
  end
end

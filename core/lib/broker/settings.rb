module Broker
  INBOUND_TOPIC = "agent.inbound".freeze
  OUTBOUND_TOPIC = "agent.outbound".freeze
  DLQ_TOPIC = "agent.dlq".freeze
  CONSUMER_GROUP = "cloudesk-broker".freeze

  # Endereços e segredos do Broker, lidos das variáveis de ambiente no momento do uso.
  module Settings
    module_function

    # Endereços do Kafka (Redpanda), separados por vírgula.
    def kafka_brokers = ENV.fetch("KAFKA_BROKERS")

    # Segredo da assinatura HMAC do webhook message.created, o mesmo do Core.
    def broker_webhook_secret = ENV.fetch("BROKER_WEBHOOK_SECRET")

    # Segredo da assinatura HMAC das chamadas a POST /api/v1/agent/actions, o mesmo do Core.
    def agent_actions_secret = ENV.fetch("AGENT_ACTIONS_SECRET")

    # Segredo da assinatura HMAC das chamadas do Core aos endpoints da DLQ, o mesmo do Core.
    def broker_dlq_secret = ENV.fetch("BROKER_DLQ_SECRET")

    # URL da API de ações do Core. O caminho assinado é o caminho da URI, com a query string.
    def core_actions_url = ENV.fetch("CORE_ACTIONS_URL")
  end
end

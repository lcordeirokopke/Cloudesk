module Agents
  # Endereço e segredo do webhook ao Broker, lidos das variáveis de ambiente no momento do uso.
  module Settings
    module_function

    # URL do webhook message.created no broker-web. O caminho assinado é o caminho da URI, com a
    # query string.
    def broker_webhook_url = ENV.fetch("BROKER_WEBHOOK_URL")

    # Segredo da assinatura HMAC do webhook (Contract::Signature), o mesmo do broker-web.
    def broker_webhook_secret = ENV.fetch("BROKER_WEBHOOK_SECRET")
  end
end

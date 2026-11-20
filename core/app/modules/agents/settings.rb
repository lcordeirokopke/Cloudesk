module Agents
  # Endereços e segredos da integração com o Broker e o agente, lidos das variáveis de ambiente no
  # momento do uso.
  module Settings
    module_function

    # URL do webhook message.created no broker-web. O caminho assinado é o caminho da URI, com a
    # query string.
    def broker_webhook_url = ENV.fetch("BROKER_WEBHOOK_URL")

    # Segredo da assinatura HMAC do webhook (Contract::Signature), o mesmo do broker-web.
    def broker_webhook_secret = ENV.fetch("BROKER_WEBHOOK_SECRET")

    # Segredo da assinatura HMAC das chamadas do Broker a POST /api/v1/agent/actions.
    def agent_actions_secret = ENV.fetch("AGENT_ACTIONS_SECRET")

    # Segredo da assinatura HMAC do GET da context_url feito pelo agente.
    def agent_context_secret = ENV.fetch("AGENT_CONTEXT_SECRET")
  end
end

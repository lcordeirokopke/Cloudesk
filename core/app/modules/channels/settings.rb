module Channels
  # Segredos e endereços dos canais, lidos das variáveis de ambiente no momento do uso.
  # Os segredos são textos aleatórios gerados para o projeto; não existe conta na Meta.
  module Settings
    module_function

    # Assinatura X-Hub-Signature-256 dos webhooks do WhatsApp.
    def whatsapp_app_secret = ENV.fetch("WHATSAPP_APP_SECRET")

    # Token da verificação GET do webhook do WhatsApp.
    def whatsapp_verify_token = ENV.fetch("WHATSAPP_VERIFY_TOKEN")

    # Bearer token do envio de mensagens do WhatsApp.
    def whatsapp_access_token = ENV.fetch("WHATSAPP_ACCESS_TOKEN")

    # Base do envio do WhatsApp, com o segmento de versão: POST {url}/{phone_number_id}/messages.
    def whatsapp_api_url = ENV.fetch("WHATSAPP_API_URL")

    # Assinatura HMAC da entrada JSON do chat (Contract::Signature).
    def chat_signing_secret = ENV.fetch("CHAT_SIGNING_SECRET")

    # Basic auth do webhook do Mailpit.
    def mailpit_webhook_user = ENV.fetch("MAILPIT_WEBHOOK_USER")
    def mailpit_webhook_password = ENV.fetch("MAILPIT_WEBHOOK_PASSWORD")

    # API HTTP do Mailpit.
    def mailpit_api_url = ENV.fetch("MAILPIT_API_URL")
  end
end

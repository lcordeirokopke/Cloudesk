module Channels
  # Webhook do Mailpit para cada e-mail recebido: POST /channels/email/mailpit, com basic auth na URL
  # (MAILPIT_WEBHOOK_USER e MAILPIT_WEBHOOK_PASSWORD). O endpoint lê só o ID do Mailpit, enfileira
  # Channels::Email::IngestJob e responde 200; a partir daí o pedido está gravado no banco e tem
  # nova tentativa. O Mailpit não reenvia webhooks com falha; Channels::Email::SweepJob recupera o
  # que se perdeu.
  class MailpitWebhooksController < ActionController::API
    include ActionController::HttpAuthentication::Basic::ControllerMethods

    before_action :authenticate

    def create
      id = params["ID"].to_s
      return head(:unprocessable_content) if id.empty?

      Email::IngestJob.perform_later(id)
      head :ok
    end

    private

    def authenticate
      authenticate_or_request_with_http_basic("Cloudesk") do |user, password|
        # & e não &&: as duas comparações rodam sempre, em tempo constante.
        ActiveSupport::SecurityUtils.secure_compare(user, Settings.mailpit_webhook_user) &
          ActiveSupport::SecurityUtils.secure_compare(password, Settings.mailpit_webhook_password)
      end
    end
  end
end

require "openssl"

module Channels
  module Whatsapp
    # Assinatura dos webhooks do WhatsApp: header X-Hub-Signature-256 com "sha256=" seguido do
    # HMAC-SHA256 em hexadecimal do corpo bruto, com o app secret.
    module Signature
      HEADER = "X-Hub-Signature-256".freeze
      PREFIX = "sha256=".freeze

      module_function

      def sign(body, secret: Settings.whatsapp_app_secret)
        "#{PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, body.to_s)}"
      end

      def valid?(body, header, secret: Settings.whatsapp_app_secret)
        return false if header.blank? || !header.start_with?(PREFIX)

        OpenSSL.secure_compare(sign(body, secret: secret), header)
      end
    end
  end
end

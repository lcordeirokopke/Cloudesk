require "net/http"

module Channels
  module Whatsapp
    # Envio de mensagem de texto no formato da Cloud API da Meta, para o simulador de canais:
    #   POST {WHATSAPP_API_URL}/{phone_number_id}/messages, com Authorization: Bearer.
    # 2xx é sucesso; 5xx e erro de rede lançam DeliveryError::Transient; os demais status lançam
    # DeliveryError::Permanent.
    module Sender
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10

      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
        SocketError, EOFError
      ].freeze

      module_function

      # phone_number_id: número da marca que envia; to: telefone do lojista em E.164;
      # message_id: id da Message do Core, no header X-Cloudesk-Message-Id.
      def deliver(phone_number_id:, to:, text:, message_id:, traceparent:)
        uri = URI("#{Settings.whatsapp_api_url.chomp('/')}/#{phone_number_id}/messages")
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{Settings.whatsapp_access_token}"
        request["Content-Type"] = "application/json"
        request["X-Cloudesk-Message-Id"] = message_id
        request["traceparent"] = traceparent
        request.body = body(to, text).to_json

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
        check!(response)
      rescue *NETWORK_ERRORS => error
        raise DeliveryError::Transient, "WhatsApp indisponível: #{error.class}: #{error.message}"
      end

      def body(to, text)
        {
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: to.to_s.delete_prefix("+"),
          type: "text",
          text: { body: text }
        }
      end

      def check!(response)
        status = response.code.to_i
        return response if status.between?(200, 299)
        raise DeliveryError::Transient, "WhatsApp respondeu #{status}" if status >= 500

        raise DeliveryError::Permanent, "WhatsApp recusou a mensagem com #{status}: #{response.body.to_s.truncate(500)}"
      end
    end
  end
end

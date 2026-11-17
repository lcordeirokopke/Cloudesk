require "openssl"

module Contract
  # Assinatura das chamadas HTTP entre Core, Broker e agente: HMAC-SHA256 com timestamp.
  # O texto assinado é "<timestamp>.<MÉTODO>.<caminho>.<corpo>": o timestamp é o horário Unix em
  # segundos, o caminho inclui a query string e o corpo é o texto bruto da requisição, vazio no GET.
  # A assinatura vale para um endpoint e para uma janela de tempo; fora da janela a chamada é
  # recusada (anti-replay).
  # Este código não acessa o banco: o Broker o usa.
  module Signature
    TIMESTAMP_HEADER = "X-Cloudesk-Timestamp".freeze
    SIGNATURE_HEADER = "X-Cloudesk-Signature".freeze
    TOLERANCE_SECONDS = 300

    class Error < StandardError; end
    class Invalid < Error; end
    class Expired < Error; end

    class << self
      # Assinatura em hexadecimal.
      def sign(secret:, timestamp:, method:, path:, body: "")
        raise ArgumentError, "segredo não informado" if secret.to_s.empty?

        OpenSSL::HMAC.hexdigest("SHA256", secret, signed_payload(timestamp, method, path, body))
      end

      # Headers de uma chamada assinada no horário now.
      def headers(secret:, method:, path:, body: "", now: Time.now)
        timestamp = now.to_i.to_s
        {
          TIMESTAMP_HEADER => timestamp,
          SIGNATURE_HEADER => sign(secret: secret, timestamp: timestamp, method: method, path: path, body: body)
        }
      end

      # Confere a janela de tempo e a assinatura. Lança Expired ou Invalid.
      def verify!(secret:, timestamp:, signature:, method:, path:, body: "", now: Time.now)
        raise Invalid, "timestamp ausente ou inválido" unless timestamp.to_s.match?(/\A\d+\z/)
        raise Invalid, "assinatura ausente" if signature.to_s.empty?
        raise Expired, "timestamp fora da janela de #{TOLERANCE_SECONDS} s" if (now.to_i - timestamp.to_i).abs > TOLERANCE_SECONDS

        expected = sign(secret: secret, timestamp: timestamp, method: method, path: path, body: body)
        raise Invalid, "assinatura não confere" unless OpenSSL.secure_compare(expected, signature.to_s)

        true
      end

      def valid?(**arguments)
        verify!(**arguments)
      rescue Error
        false
      end

      private

      def signed_payload(timestamp, method, path, body)
        "#{timestamp}.#{method.to_s.upcase}.#{path}.#{body}"
      end
    end
  end
end

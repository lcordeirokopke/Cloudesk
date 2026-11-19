require "net/http"

module Agents
  # Envio do webhook ao Broker: POST JSON em BROKER_WEBHOOK_URL, assinado com HMAC-SHA256 e
  # timestamp (Contract::Signature) sobre os mesmos bytes do corpo enviado, com o traceparent do salto.
  # Cada envio abre uma conexão nova e gera timestamp e assinatura próprios.
  # 2xx é sucesso; 408, 429, 5xx e erro de rede lançam WebhookError::Transient; os demais status
  # lançam WebhookError::Permanent.
  module BrokerClient
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5

    TRANSIENT_STATUSES = [ 408, 429 ].freeze

    # SocketError cobre a falha de resolução de nome (Socket::ResolutionError).
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE, SocketError, EOFError
    ].freeze

    module_function

    # body: corpo JSON já serializado; traceparent: contexto W3C do salto, no header traceparent.
    def deliver(body:, traceparent:, now: Time.now)
      uri = URI(Settings.broker_webhook_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["traceparent"] = traceparent
      Contract::Signature.headers(
        secret: Settings.broker_webhook_secret, method: "POST", path: uri.request_uri, body: body, now: now
      ).each { |name, value| request[name] = value }
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
      check!(response)
    rescue *NETWORK_ERRORS => error
      raise WebhookError::Transient, "Broker indisponível: #{error.class}: #{error.message}"
    end

    def check!(response)
      status = response.code.to_i
      return response if status.between?(200, 299)
      raise WebhookError::Transient, "Broker respondeu #{status}" if status >= 500 || TRANSIENT_STATUSES.include?(status)

      raise WebhookError::Permanent, "Broker recusou o webhook com #{status}: #{response.body.to_s.truncate(500)}"
    end
  end
end

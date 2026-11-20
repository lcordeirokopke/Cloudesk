require "net/http"

module Broker
  # Falha transitória na chamada ao Core: 408, 429, 5xx ou erro de rede. O consumidor lança e o
  # Karafka reprocessa a mensagem depois da pausa. status é nil no erro de rede.
  class TransientError < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end

  # Chamada à API de ações do Core: POST em CORE_ACTIONS_URL com o valor Kafka da ação sem
  # alteração, assinado com HMAC-SHA256 e timestamp (Contract::Signature) sobre os mesmos bytes, com
  # a Idempotency-Key e o traceparent do salto. Cada chamada abre uma conexão nova e gera timestamp e
  # assinatura próprios.
  #
  # Classificação da resposta:
  #   200 e 409 (stale, rejected)  resultado final
  #   408, 429, 5xx, erro de rede  lança TransientError
  #   demais status                DLQ
  module CoreClient
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 5

    FINAL_STATUSES = [ 200, 409 ].freeze
    TRANSIENT_STATUSES = [ 408, 429 ].freeze

    # SocketError cobre a falha de resolução de nome (Socket::ResolutionError).
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE, SocketError, EOFError
    ].freeze

    Result = Data.define(:outcome, :status, :body) do
      def final? = outcome == :final
      def dead_letter? = outcome == :dead_letter
    end

    module_function

    # body: valor Kafka da ação, sem alteração; traceparent: contexto W3C do salto.
    def deliver(body:, idempotency_key:, traceparent:, now: Time.now)
      uri = URI(Settings.core_actions_url)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request[Contract::IdempotencyKey::HEADER] = idempotency_key
      request["traceparent"] = traceparent
      Contract::Signature.headers(
        secret: Settings.agent_actions_secret, method: "POST", path: uri.request_uri, body: body, now: now
      ).each { |name, value| request[name] = value }
      request.body = body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
      classify(response)
    rescue *NETWORK_ERRORS => failure
      raise TransientError, "Core indisponível: #{failure.class}: #{failure.message}"
    end

    def classify(response)
      status = response.code.to_i
      body = response.body.to_s
      return Result.new(outcome: :final, status: status, body: body) if FINAL_STATUSES.include?(status)
      if status >= 500 || TRANSIENT_STATUSES.include?(status)
        raise TransientError.new("Core respondeu #{status}: #{body[0, 500]}", status: status)
      end

      Result.new(outcome: :dead_letter, status: status, body: body)
    end
  end
end

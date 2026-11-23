module Broker
  # Endpoint Rack do broker-web. Recebe o webhook message.created do Core e publica o corpo em
  # agent.inbound; responde 200 somente depois da confirmação do Kafka.
  #
  #   POST /webhooks/message-created
  #     200 {topic, partition, offset}       mensagem confirmada pelo Kafka
  #     401 invalid_signature | expired_timestamp
  #     422 invalid_payload                  JSON inválido ou fora do schema webhook.message-created
  #     503 kafka_unavailable                sem confirmação do Kafka; o Core reenvia
  #   GET /up                                healthcheck
  #   GET /metrics                           métricas no formato de texto do Prometheus (Broker::Metrics)
  #
  # A mensagem Kafka leva o corpo recebido byte a byte, a chave conversation_id e os headers brand,
  # traceparent (mesmo trace_id, parent_id do Broker) e broker_received_at (horário de chegada do
  # webhook, carimbado antes de qualquer conferência).
  #
  # Cada resposta do POST conta em cloudesk_broker_webhooks_total{status}. Na resposta 200, depois da
  # confirmação do Kafka, o tempo desde o received_at do corpo (recebimento HTTP no Core) é observado
  # em cloudesk_broker_inbound_latency_seconds{brand}: a latência entrada → Kafka.
  class WebhookApp
    WEBHOOK_PATH = "/webhooks/message-created".freeze
    HEALTH_PATH = "/up".freeze
    METRICS_PATH = "/metrics".freeze
    WEBHOOK_SCHEMA = "webhook.message-created".freeze
    HEADERS_SCHEMA = "kafka.inbound-headers".freeze
    JSON_HEADERS = { "content-type" => "application/json" }.freeze

    def initialize(producer:, logger: Logger.new($stdout), metrics: Metrics.default)
      @producer = producer
      @logger = logger
      @metrics = metrics
    end

    def call(env)
      request = Rack::Request.new(env)

      case request.path_info
      when WEBHOOK_PATH
        return method_not_allowed("POST") unless request.post?

        message_created(request, received_at: Time.now.utc).tap { |status, _| @metrics.count_webhook(status) }
      when HEALTH_PATH
        return method_not_allowed("GET") unless request.get?

        [ 200, { "content-type" => "text/plain" }, [ "ok" ] ]
      when METRICS_PATH
        return method_not_allowed("GET") unless request.get?

        [ 200, { "content-type" => Prometheus::Client::Formats::Text::CONTENT_TYPE }, [ @metrics.render ] ]
      else
        error(404, "not_found", "rota não encontrada")
      end
    end

    private

    def message_created(request, received_at:)
      body = request.body.read.to_s
      verify_signature!(request, body)

      event = parse(body)
      return error(422, "invalid_payload", "corpo JSON inválido") unless event.is_a?(Hash)

      schema_errors = Contract::Schemas.errors(WEBHOOK_SCHEMA, event)
      return error(422, "invalid_payload", schema_errors.join("; ")) if schema_errors.any?

      publish(body, event, request, received_at)
    rescue Contract::Signature::Expired
      error(401, "expired_timestamp", "timestamp fora da janela de #{Contract::Signature::TOLERANCE_SECONDS} s")
    rescue Contract::Signature::Invalid
      error(401, "invalid_signature", "assinatura inválida")
    end

    def verify_signature!(request, body)
      Contract::Signature.verify!(
        secret: Settings.broker_webhook_secret,
        timestamp: request.get_header("HTTP_X_CLOUDESK_TIMESTAMP"),
        signature: request.get_header("HTTP_X_CLOUDESK_SIGNATURE"),
        method: request.request_method, path: request.fullpath, body: body
      )
    end

    def parse(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def publish(body, event, request, received_at)
      headers = Contract::Schemas.validate!(HEADERS_SCHEMA, {
        "brand" => event.fetch("brand"),
        "traceparent" => TraceContext.continue(request.get_header("HTTP_TRACEPARENT")).to_s,
        "broker_received_at" => received_at.iso8601(3)
      })

      report = begin
        @producer.produce_sync(topic: INBOUND_TOPIC, payload: body, key: event.fetch("conversation_id"), headers: headers)
      rescue StandardError => failure
        @logger.error("agent.inbound sem confirmação do Kafka: #{failure.class}: #{failure.message}")
        return error(503, "kafka_unavailable", "Kafka não confirmou a publicação")
      end
      observe_inbound_latency(event)

      json(200, { "topic" => INBOUND_TOPIC, "partition" => report.partition, "offset" => report.offset })
    end

    # Latência entrada → Kafka: agora, logo depois da confirmação do Kafka, menos o received_at do
    # corpo. Um valor negativo (relógios) é observado como 0.
    def observe_inbound_latency(event)
      seconds = Time.now.utc - Time.iso8601(event.fetch("received_at"))
      @metrics.observe_inbound_latency(brand: event.fetch("brand"), seconds: [ seconds, 0 ].max)
    end

    def method_not_allowed(allowed)
      status, headers, body = error(405, "method_not_allowed", "método não permitido")
      [ status, headers.merge("allow" => allowed), body ]
    end

    def error(status, code, message)
      json(status, { "status" => "error", "error" => code, "message" => message })
    end

    def json(status, data)
      [ status, JSON_HEADERS.dup, [ JSON.generate(data) ] ]
    end
  end
end

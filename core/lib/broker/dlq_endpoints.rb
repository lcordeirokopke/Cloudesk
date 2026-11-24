module Broker
  # Endpoints da DLQ no broker-web, chamados pela tela /admin/dlq do Core (Admin::DlqClient). O Kafka
  # fica só no Broker: o Core lista e republica por aqui. As chamadas são assinadas com
  # Contract::Signature e BROKER_DLQ_SECRET, sobre método, caminho com a query string e corpo.
  #
  #   GET /dlq/messages?brand=<slug>&limit=<n>
  #     200 {messages: [...]}       as últimas limit mensagens de cada partição de agent.dlq com o
  #                                 header brand igual ao slug, por dlq_failed_at decrescente, até
  #                                 limit no total (padrão 50, de 1 a MAX_LIMIT)
  #   POST /dlq/messages/<partition>/<offset>/reprocess  corpo {"brand": "<slug>"}
  #     200 {source, destination, diagnostics}  a mensagem republicada em agent.outbound, com a
  #                                 mesma chave, o mesmo valor byte a byte e os headers originais sem
  #                                 os de diagnóstico (schema kafka.dlq-headers)
  #     404 not_found               não existe mensagem na posição
  #     422 brand_mismatch          o header brand da mensagem difere do corpo
  #   Nos dois:
  #     401 invalid_signature | expired_timestamp
  #     422 invalid_payload         marca, limite ou corpo ausente ou inválido
  #     503 kafka_unavailable       leitura ou publicação sem resposta do Kafka
  #
  # A republicação usa o produtor do broker-web (BROKER_PRODUCER). O broker-consumer consome a ação
  # republicada pelo fluxo normal, e o Core deduplica pela Idempotency-Key.
  class DlqEndpoints
    LIST_PATH = "/dlq/messages".freeze
    REPROCESS_PATH = %r{\A/dlq/messages/(\d+)/(\d+)/reprocess\z}
    DEFAULT_LIMIT = 50
    MAX_LIMIT = 500
    HEADERS_SCHEMA = "kafka.dlq-headers".freeze
    JSON_HEADERS = { "content-type" => "application/json" }.freeze

    def self.handles?(path)
      path == LIST_PATH || path.start_with?("#{LIST_PATH}/")
    end

    def initialize(producer:, logger: Logger.new($stdout), reader: DlqReader.new)
      @producer = producer
      @logger = logger
      @reader = reader
    end

    def call(request)
      path = request.path_info
      if path == LIST_PATH
        return method_not_allowed("GET") unless request.get?

        signed(request) { list(request) }
      elsif (match = REPROCESS_PATH.match(path))
        return method_not_allowed("POST") unless request.post?

        signed(request) { |body| reprocess(Integer(match[1]), Integer(match[2]), body) }
      else
        error(404, "not_found", "rota não encontrada")
      end
    end

    private

    # Sem corpo, o Rack pode não ter rack.input (GET).
    def signed(request)
      body = request.body&.read.to_s
      Contract::Signature.verify!(
        secret: Settings.broker_dlq_secret,
        timestamp: request.get_header("HTTP_X_CLOUDESK_TIMESTAMP"),
        signature: request.get_header("HTTP_X_CLOUDESK_SIGNATURE"),
        method: request.request_method, path: request.fullpath, body: body
      )
      yield body
    rescue Contract::Signature::Expired
      error(401, "expired_timestamp", "timestamp fora da janela de #{Contract::Signature::TOLERANCE_SECONDS} s")
    rescue Contract::Signature::Invalid
      error(401, "invalid_signature", "assinatura inválida")
    end

    def list(request)
      brand = request.GET["brand"].to_s
      return error(422, "invalid_payload", "informe brand") if brand.empty?

      limit = parse_limit(request.GET["limit"])
      return error(422, "invalid_payload", "limit deve ser um inteiro de 1 a #{MAX_LIMIT}") if limit.nil?

      messages = kafka { @reader.recent(limit: limit) }
      return messages if rack_response?(messages)

      selected = messages.select { |message| message.brand == brand }
                         .sort_by { |message| [ message.failed_at.to_s, message.partition, message.offset ] }
                         .reverse
                         .first(limit)
      json(200, { "messages" => selected.map(&:to_h) })
    end

    def reprocess(partition, offset, body)
      brand = parse_brand(body)
      return error(422, "invalid_payload", "corpo deve ser {\"brand\": \"<slug>\"}") if brand.nil?

      message = kafka { @reader.find(partition: partition, offset: offset) }
      return message if rack_response?(message)
      return error(404, "not_found", "nenhuma mensagem em #{DLQ_TOPIC}/#{partition}@#{offset}") if message.nil?
      return error(422, "brand_mismatch", "a mensagem é da marca #{message.brand.inspect}") unless message.brand == brand

      publish(message)
    end

    def publish(message)
      diagnostic_names = Contract::Schemas.schema(HEADERS_SCHEMA).fetch("properties").keys
      headers = message.headers.except(*diagnostic_names)

      report = begin
        @producer.produce_sync({ topic: OUTBOUND_TOPIC, payload: message.value.b, key: message.key,
                                 headers: headers }.compact)
      rescue StandardError => failure
        @logger.error("#{OUTBOUND_TOPIC} sem confirmação do Kafka na republicação da DLQ: #{failure.class}: #{failure.message}")
        return error(503, "kafka_unavailable", "Kafka não confirmou a publicação")
      end

      source = { "topic" => DLQ_TOPIC, "partition" => message.partition, "offset" => message.offset }
      destination = { "topic" => OUTBOUND_TOPIC, "partition" => report.partition, "offset" => report.offset }
      @logger.info("DLQ reprocessada: #{DLQ_TOPIC}/#{message.partition}@#{message.offset} -> " \
                   "#{OUTBOUND_TOPIC}/#{report.partition}@#{report.offset}")
      json(200, { "source" => source, "destination" => destination,
                  "diagnostics" => message.headers.slice(*diagnostic_names) })
    end

    # Executa a leitura no Kafka; devolve a resposta 503 quando o Kafka não responde.
    def kafka
      yield
    rescue Rdkafka::RdkafkaError, Rdkafka::AbstractHandle::WaitTimeoutError => failure
      @logger.error("#{DLQ_TOPIC} sem resposta do Kafka: #{failure.class}: #{failure.message}")
      error(503, "kafka_unavailable", "Kafka não respondeu à leitura de #{DLQ_TOPIC}")
    end

    def rack_response?(value)
      value.is_a?(Array) && value.size == 3 && value.first.is_a?(Integer)
    end

    def parse_limit(value)
      return DEFAULT_LIMIT if value.nil? || value.to_s.empty?
      return nil unless value.to_s.match?(/\A\d+\z/)

      limit = value.to_i
      limit.between?(1, MAX_LIMIT) ? limit : nil
    end

    def parse_brand(body)
      data = JSON.parse(body)
      brand = data.is_a?(Hash) ? data["brand"] : nil
      brand.is_a?(String) && !brand.empty? ? brand : nil
    rescue JSON::ParserError
      nil
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

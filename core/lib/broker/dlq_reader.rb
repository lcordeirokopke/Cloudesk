module Broker
  # Leitura de agent.dlq pelo broker-web, para a tela de reprocessamento do Core. Usa o
  # Karafka::Admin com a configuração Kafka própria (endereços e client.id), sem o Karafka::App
  # configurado: cada leitura abre e fecha o próprio consumidor, por assign, sem grupo de consumo nem
  # offset confirmado.
  #
  #   recent(limit:)            as últimas limit mensagens de cada partição do tópico
  #   find(partition:, offset:) a mensagem na posição, ou nil quando ela não existe
  #
  # As falhas do Kafka sobem como Rdkafka::RdkafkaError ou Rdkafka::AbstractHandle::WaitTimeoutError.
  class DlqReader
    CLIENT_ID = "cloudesk-broker-web".freeze

    # headers: headers da mensagem, com o último valor de cada nome; value: bytes do valor, em UTF-8
    # (os bytes inválidos são substituídos só no to_h). Em to_h, type e inbound_event_id são campos
    # da ação quando o valor é um objeto JSON, senão nil.
    Message = Data.define(:partition, :offset, :key, :headers, :value, :timestamp) do
      def brand = headers["brand"]
      def failed_at = headers["dlq_failed_at"]
      def reason = headers["dlq_reason"]

      def action
        parsed = JSON.parse(value.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      def to_h
        parsed = action
        {
          "partition" => partition, "offset" => offset, "key" => key, "headers" => headers, "value" => value.scrub,
          "type" => parsed&.fetch("type", nil), "inbound_event_id" => parsed&.fetch("inbound_event_id", nil),
          "timestamp" => timestamp&.utc&.iso8601(3)
        }
      end
    end

    def initialize(topic: DLQ_TOPIC, admin: nil)
      @topic = topic
      @admin = admin
    end

    def recent(limit:)
      (0...partition_count).flat_map do |partition|
        admin.read_topic(@topic, partition, limit).map { |message| build(message) }
      end
    end

    def find(partition:, offset:)
      return nil unless partition < partition_count

      low, high = admin.read_watermark_offsets(@topic, partition)
      return nil unless offset >= low && offset < high

      message = admin.read_topic(@topic, partition, 1, offset).first
      message && message.offset == offset ? build(message) : nil
    end

    private

    def admin
      @admin ||= Karafka::Admin.new(kafka: { "bootstrap.servers": Settings.kafka_brokers, "client.id": CLIENT_ID })
    end

    def partition_count
      admin.topic_info(@topic).fetch(:partition_count)
    end

    def build(message)
      headers = (message.raw_headers || {}).transform_values { |value| value.is_a?(Array) ? value.last : value }
      Message.new(
        partition: message.partition, offset: message.offset, key: message.raw_key, headers: headers,
        value: message.raw_payload.to_s.dup.force_encoding(Encoding::UTF_8), timestamp: message.timestamp
      )
    end
  end
end

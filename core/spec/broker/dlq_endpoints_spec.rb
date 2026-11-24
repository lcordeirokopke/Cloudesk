require "broker_helper"

RSpec.describe Broker::DlqEndpoints, broker: true do
  include Rack::Test::Methods

  # Leitor falso de agent.dlq, com as mensagens informadas.
  let(:reader_class) do
    Class.new do
      attr_reader :limits

      def initialize(messages)
        @messages = messages
        @limits = []
      end

      def recent(limit:)
        @limits << limit
        @messages
      end

      def find(partition:, offset:)
        @messages.find { |message| message.partition == partition && message.offset == offset }
      end
    end
  end

  let(:producer) do
    WaterDrop::Producer.new do |config|
      config.kafka = { "bootstrap.servers": broker_env("KAFKA_BROKERS") }
      config.client_class = WaterDrop::Clients::Buffered
      config.logger = Logger.new(IO::NULL)
    end
  end
  let(:value) { contract_example("action", "reply") }
  let(:messages) do
    [
      dlq_message(0, 3, failed_at: "2026-11-23T14:00:01.000Z"),
      dlq_message(1, 7, failed_at: "2026-11-23T14:00:03.000Z"),
      dlq_message(2, 1, failed_at: "2026-11-23T14:00:02.000Z", brand: "jim"),
      dlq_message(3, 0, failed_at: "2026-11-23T14:00:04.000Z", brand: nil)
    ]
  end
  let(:reader) { reader_class.new(messages) }
  let(:app) do
    endpoints = described_class.new(producer: producer, logger: Logger.new(IO::NULL), reader: reader)
    Broker::WebhookApp.new(producer: producer, logger: Logger.new(IO::NULL), metrics: Broker::Metrics.new, dlq: endpoints)
  end

  after { producer.close }

  def dlq_message(partition, offset, failed_at:, brand: "infinitepay")
    headers = {
      "brand" => brand, "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-7d3e8a1c9b2f4e60-01",
      "dlq_reason" => "core_rejected", "dlq_status" => "422", "dlq_source_topic" => "agent.outbound",
      "dlq_source_partition" => partition.to_s, "dlq_source_offset" => "9", "dlq_failed_at" => failed_at
    }.compact
    Broker::DlqReader::Message.new(partition: partition, offset: offset, key: "conversa-#{partition}", headers: headers,
                                   value: value, timestamp: Time.utc(2026, 11, 23, 14))
  end

  def signed(method, target, body: "", secret: broker_env("BROKER_DLQ_SECRET"), now: Time.now)
    headers = Contract::Signature.headers(secret: secret, method: method, path: target, body: body, now: now)
    header "X-Cloudesk-Timestamp", headers.fetch("X-Cloudesk-Timestamp")
    header "X-Cloudesk-Signature", headers.fetch("X-Cloudesk-Signature")
    header "Content-Type", "application/json"
    method == "GET" ? get(target) : post(target, body)
  end

  def response_json
    JSON.parse(last_response.body)
  end

  def published
    producer.client.messages
  end

  describe "assinatura" do
    it "recusa a assinatura inválida com 401" do
      signed("GET", "/dlq/messages?brand=infinitepay", secret: "outro")

      expect(last_response.status).to eq(401)
      expect(response_json).to include("error" => "invalid_signature")
    end

    it "recusa o timestamp vencido com 401" do
      signed("GET", "/dlq/messages?brand=infinitepay", now: Time.now - 301)

      expect(last_response.status).to eq(401)
      expect(response_json).to include("error" => "expired_timestamp")
    end

    it "assina o caminho com a query string" do
      headers = Contract::Signature.headers(secret: broker_env("BROKER_DLQ_SECRET"), method: "GET", path: "/dlq/messages", body: "")
      header "X-Cloudesk-Timestamp", headers.fetch("X-Cloudesk-Timestamp")
      header "X-Cloudesk-Signature", headers.fetch("X-Cloudesk-Signature")
      get "/dlq/messages?brand=infinitepay"

      expect(last_response.status).to eq(401)
    end

    it "recusa a republicação sem assinatura, sem publicar" do
      post "/dlq/messages/0/3/reprocess", JSON.generate("brand" => "infinitepay")

      expect(last_response.status).to eq(401)
      expect(published).to be_empty
    end
  end

  describe "GET /dlq/messages" do
    it "lista as mensagens da marca por dlq_failed_at decrescente" do
      signed("GET", "/dlq/messages?brand=infinitepay&limit=50")

      expect(last_response.status).to eq(200)
      listed = response_json.fetch("messages")
      expect(listed.map { |item| [ item["partition"], item["offset"] ] }).to eq([ [ 1, 7 ], [ 0, 3 ] ])
      expect(listed.first).to include("key" => "conversa-1", "value" => value, "type" => "reply",
                                      "inbound_event_id" => JSON.parse(value).fetch("inbound_event_id"))
      expect(listed.first.fetch("headers")).to include("dlq_reason" => "core_rejected", "dlq_status" => "422")
    end

    it "lê limit mensagens por partição e devolve até limit" do
      signed("GET", "/dlq/messages?brand=infinitepay&limit=1")

      expect(reader.limits).to eq([ 1 ])
      expect(response_json.fetch("messages").map { |item| item["offset"] }).to eq([ 7 ])
    end

    it "usa limit 50 por padrão" do
      signed("GET", "/dlq/messages?brand=jim")

      expect(reader.limits).to eq([ 50 ])
      expect(response_json.fetch("messages").size).to eq(1)
    end

    it "recusa marca ausente e limit inválido com 422" do
      signed("GET", "/dlq/messages")
      expect(last_response.status).to eq(422)

      signed("GET", "/dlq/messages?brand=jim&limit=0")
      expect(last_response.status).to eq(422)

      signed("GET", "/dlq/messages?brand=jim&limit=abc")
      expect(last_response.status).to eq(422)
    end

    it "responde 503 quando o Kafka não responde à leitura" do
      allow(reader).to receive(:recent).and_raise(Rdkafka::RdkafkaError.new(-185))

      signed("GET", "/dlq/messages?brand=infinitepay")

      expect(last_response.status).to eq(503)
      expect(response_json).to include("error" => "kafka_unavailable")
    end

    it "recusa outro método com 405" do
      post "/dlq/messages", ""

      expect(last_response.status).to eq(405)
    end
  end

  describe "POST /dlq/messages/<partition>/<offset>/reprocess" do
    let(:body) { JSON.generate("brand" => "infinitepay") }

    it "republica em agent.outbound com a mesma chave e o mesmo valor, sem os headers de diagnóstico" do
      signed("POST", "/dlq/messages/1/7/reprocess", body: body)

      expect(last_response.status).to eq(200)
      expect(published.size).to eq(1)
      message = published.first
      expect(message[:topic]).to eq("agent.outbound")
      expect(message[:key]).to eq("conversa-1")
      expect(message[:payload].bytes).to eq(value.bytes)
      expect(message[:headers]).to eq("brand" => "infinitepay",
                                      "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-7d3e8a1c9b2f4e60-01")
      expect(response_json).to eq(
        "source" => { "topic" => "agent.dlq", "partition" => 1, "offset" => 7 },
        "destination" => { "topic" => "agent.outbound", "partition" => 0, "offset" => 0 },
        "diagnostics" => {
          "dlq_reason" => "core_rejected", "dlq_status" => "422", "dlq_source_topic" => "agent.outbound",
          "dlq_source_partition" => "1", "dlq_source_offset" => "9", "dlq_failed_at" => "2026-11-23T14:00:03.000Z"
        }
      )
    end

    it "responde 404 para offset inexistente" do
      signed("POST", "/dlq/messages/1/8/reprocess", body: body)

      expect(last_response.status).to eq(404)
      expect(response_json).to include("error" => "not_found")
      expect(published).to be_empty
    end

    it "responde 422 brand_mismatch para mensagem de outra marca ou sem marca" do
      signed("POST", "/dlq/messages/2/1/reprocess", body: body)
      expect(last_response.status).to eq(422)
      expect(response_json).to include("error" => "brand_mismatch")

      signed("POST", "/dlq/messages/3/0/reprocess", body: body)
      expect(response_json).to include("error" => "brand_mismatch")
      expect(published).to be_empty
    end

    it "recusa corpo sem marca com 422" do
      signed("POST", "/dlq/messages/1/7/reprocess", body: "{}")

      expect(last_response.status).to eq(422)
      expect(response_json).to include("error" => "invalid_payload")
    end

    it "responde 503 kafka_unavailable sem confirmação da publicação" do
      allow(producer).to receive(:produce_sync).and_raise(WaterDrop::Errors::ProduceError, "sem confirmação")

      signed("POST", "/dlq/messages/1/7/reprocess", body: body)

      expect(last_response.status).to eq(503)
      expect(response_json).to include("error" => "kafka_unavailable")
    end

    it "responde 503 quando o Kafka não responde à leitura da mensagem" do
      allow(reader).to receive(:find).and_raise(Rdkafka::RdkafkaError.new(-185))

      signed("POST", "/dlq/messages/1/7/reprocess", body: body)

      expect(last_response.status).to eq(503)
    end
  end
end

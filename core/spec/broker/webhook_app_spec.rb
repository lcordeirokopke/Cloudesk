require "broker_helper"

RSpec.describe Broker::WebhookApp, broker: true do
  include Rack::Test::Methods

  let(:producer) do
    WaterDrop::Producer.new do |config|
      config.kafka = { "bootstrap.servers": broker_env("KAFKA_BROKERS") }
      config.client_class = WaterDrop::Clients::Buffered
      config.logger = Logger.new(IO::NULL)
    end
  end
  let(:app) { described_class.new(producer: producer, logger: Logger.new(IO::NULL)) }
  let(:path) { "/webhooks/message-created" }
  let(:body) { contract_example("webhook.message-created", "whatsapp-infinitepay") }
  let(:event) { JSON.parse(body) }
  let(:incoming_traceparent) { "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }

  after { producer.close }

  def signed_post(body:, secret: broker_env("BROKER_WEBHOOK_SECRET"), now: Time.now, target: path)
    headers = Contract::Signature.headers(secret: secret, method: "POST", path: target, body: body, now: now)
    header "X-Cloudesk-Timestamp", headers.fetch("X-Cloudesk-Timestamp")
    header "X-Cloudesk-Signature", headers.fetch("X-Cloudesk-Signature")
    header "traceparent", incoming_traceparent
    header "Content-Type", "application/json"
    post target, body
  end

  def published
    producer.client.messages
  end

  def response_json
    JSON.parse(last_response.body)
  end

  describe "POST /webhooks/message-created" do
    it "publica o corpo inalterado em agent.inbound, com a chave da conversa, e responde 200 com a posição" do
      signed_post(body: body)

      expect(last_response.status).to eq(200)
      expect(published.size).to eq(1)
      message = published.first
      expect(message[:topic]).to eq("agent.inbound")
      expect(message[:payload]).to eq(body)
      expect(message[:payload].bytes).to eq(body.bytes)
      expect(message[:key]).to eq(event.fetch("conversation_id"))
      expect(response_json).to eq("topic" => "agent.inbound", "partition" => 0, "offset" => 0)
    end

    it "grava os headers brand, traceparent e broker_received_at conforme kafka.inbound-headers" do
      received_at = Time.utc(2026, 11, 13, 14, 2, 11, 530_123)
      allow(Time).to receive(:now).and_return(received_at)

      signed_post(body: body)

      headers = published.first.fetch(:headers)
      expect(Contract::Schemas.errors("kafka.inbound-headers", headers)).to eq([])
      expect(headers.fetch("brand")).to eq(event.fetch("brand"))
      expect(headers.fetch("broker_received_at")).to eq("2026-11-13T14:02:11.530Z")
    end

    it "mantém o trace_id do Core e gera parent_id próprio no traceparent" do
      signed_post(body: body)

      traceparent = TraceContext.parse(published.first.fetch(:headers).fetch("traceparent"))
      incoming = TraceContext.parse(incoming_traceparent)
      expect(traceparent.trace_id).to eq(incoming.trace_id)
      expect(traceparent.parent_id).not_to eq(incoming.parent_id)
    end

    it "assina o caminho com a query string" do
      signed_post(body: body, target: "#{path}?origem=teste")

      expect(last_response.status).to eq(200)
    end

    it "recusa com 401 invalid_signature a assinatura que não confere" do
      signed_post(body: body, secret: "outro-segredo")

      expect(last_response.status).to eq(401)
      expect(response_json).to include("status" => "error", "error" => "invalid_signature")
      expect(published).to be_empty
    end

    it "recusa com 401 invalid_signature o corpo alterado depois da assinatura" do
      headers = Contract::Signature.headers(secret: broker_env("BROKER_WEBHOOK_SECRET"), method: "POST", path: path, body: body)
      headers.each { |name, value| header name, value }
      post path, body.sub("Meu", "Seu")

      expect(last_response.status).to eq(401)
      expect(response_json.fetch("error")).to eq("invalid_signature")
      expect(published).to be_empty
    end

    it "recusa com 401 invalid_signature a requisição sem assinatura" do
      post path, body

      expect(last_response.status).to eq(401)
      expect(response_json.fetch("error")).to eq("invalid_signature")
    end

    it "recusa com 401 expired_timestamp o timestamp fora da janela" do
      signed_post(body: body, now: Time.now - Contract::Signature::TOLERANCE_SECONDS - 1)

      expect(last_response.status).to eq(401)
      expect(response_json.fetch("error")).to eq("expired_timestamp")
      expect(published).to be_empty
    end

    it "recusa com 422 invalid_payload o JSON inválido" do
      signed_post(body: "{nao e json")

      expect(last_response.status).to eq(422)
      expect(response_json.fetch("error")).to eq("invalid_payload")
      expect(published).to be_empty
    end

    it "recusa com 422 invalid_payload o JSON que não é objeto" do
      signed_post(body: "[]")

      expect(last_response.status).to eq(422)
      expect(response_json.fetch("error")).to eq("invalid_payload")
    end

    it "recusa com 422 invalid_payload o corpo fora do schema webhook.message-created" do
      signed_post(body: JSON.generate(event.except("context_url")))

      expect(last_response.status).to eq(422)
      expect(response_json.fetch("error")).to eq("invalid_payload")
      expect(published).to be_empty
    end

    it "responde 503 kafka_unavailable quando o Kafka não confirma a publicação" do
      allow(producer).to receive(:produce_sync).and_raise(WaterDrop::Errors::ProduceError, "msg_timed_out")

      signed_post(body: body)

      expect(last_response.status).to eq(503)
      expect(response_json.fetch("error")).to eq("kafka_unavailable")
    end

    it "responde 405 a outro método" do
      get path

      expect(last_response.status).to eq(405)
      expect(last_response.headers["allow"]).to eq("POST")
    end
  end

  describe "GET /up" do
    it "responde 200" do
      get "/up"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to eq("ok")
    end
  end

  it "responde 404 fora das rotas" do
    post "/webhooks/outro", body

    expect(last_response.status).to eq(404)
  end
end

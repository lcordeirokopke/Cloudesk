require "broker_helper"

RSpec.describe Broker::ActionsConsumer, broker: true do
  include Karafka::Testing::RSpec::Helpers

  subject(:consumer) { karafka.consumer_for("agent.outbound") }

  let(:url) { broker_env("CORE_ACTIONS_URL") }
  let(:payload) { contract_example("action", "reply") }
  let(:action) { JSON.parse(payload) }
  let(:headers) { { "brand" => action.fetch("brand"), "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-7d3e8a1c9b2f4e60-01" } }

  before { allow(Karafka.logger).to receive(:warn) }

  def produce(value = payload, offset: 0)
    karafka.produce(value, key: action.fetch("conversation_id"), headers: headers, partition: 3, offset: offset)
  end

  def dead_letters
    karafka.produced_messages.select { |message| message[:topic] == "agent.dlq" }
  end

  def consumed_up_to
    consumer.coordinator.seek_offset
  end

  it "chama o Core com o valor sem alteração e a Idempotency-Key derivada da ação" do
    stub_request(:post, url).to_return(status: 200, body: '{"status":"accepted"}')
    produce

    consumer.consume

    expect(WebMock).to(have_requested(:post, url).with do |request|
      request.body == payload &&
        request.headers.find { |key, _| key.casecmp?("Idempotency-Key") }&.last == "#{action.fetch('inbound_event_id')}:reply"
    end)
  end

  it "continua o trace do header traceparent" do
    stub_request(:post, url).to_return(status: 200)
    produce

    consumer.consume

    expect(WebMock).to(have_requested(:post, url).with do |request|
      sent = TraceContext.parse(request.headers.find { |key, _| key.casecmp?("traceparent") }&.last)
      sent.trace_id == "4bf92f3577b34da6a3ce929d0e0e4736" && sent.parent_id != "7d3e8a1c9b2f4e60"
    end)
  end

  it "marca a ação aceita (200) e não publica na DLQ" do
    stub_request(:post, url).to_return(status: 200, body: '{"status":"accepted"}')
    produce

    consumer.consume

    expect(consumed_up_to).to eq(1)
    expect(dead_letters).to be_empty
  end

  %w[stale rejected].each do |status|
    it "marca a ação recusada com 409 #{status} e não publica na DLQ" do
      stub_request(:post, url).to_return(status: 409, body: JSON.generate("status" => status))
      produce

      consumer.consume

      expect(consumed_up_to).to eq(1)
      expect(dead_letters).to be_empty
    end
  end

  [ 400, 401, 404, 422 ].each do |status|
    it "publica na DLQ a ação recusada com #{status}, com chave, payload e headers originais mais os de diagnóstico" do
      stub_request(:post, url).to_return(status: status, body: '{"status":"error"}')
      produce

      consumer.consume

      expect(consumed_up_to).to eq(1)
      expect(dead_letters.size).to eq(1)
      dead_letter = dead_letters.first
      expect(dead_letter[:key]).to eq(action.fetch("conversation_id"))
      expect(dead_letter[:payload]).to eq(payload)
      expect(dead_letter[:headers]).to include(headers)
      expect(dead_letter[:headers]).to include(
        "dlq_reason" => "core_rejected", "dlq_status" => status.to_s, "dlq_source_topic" => "agent.outbound",
        "dlq_source_partition" => "3", "dlq_source_offset" => "0"
      )
      expect(Contract::Schemas.errors("kafka.dlq-headers", dead_letter[:headers])).to eq([])
    end
  end

  [ "{nao e json", "[]", JSON.generate("type" => "reply"), JSON.generate("inbound_event_id" => "x", "type" => "outro") ].each do |value|
    it "publica na DLQ sem chamar o Core o valor sem Idempotency-Key: #{value}" do
      produce(value)

      consumer.consume

      expect(WebMock).not_to have_requested(:post, url)
      expect(consumed_up_to).to eq(1)
      expect(dead_letters.size).to eq(1)
      expect(dead_letters.first[:payload]).to eq(value)
      expect(dead_letters.first[:headers]).to include("dlq_reason" => "invalid_message")
      expect(dead_letters.first[:headers]).not_to have_key("dlq_status")
    end
  end

  it "lança na falha transitória antes da última tentativa, sem marcar e sem DLQ" do
    stub_request(:post, url).to_return(status: 503)
    allow(consumer).to receive(:attempt).and_return(9)
    produce

    expect { consumer.consume }.to raise_error(Broker::TransientError)
    expect(consumed_up_to).to eq(0)
    expect(dead_letters).to be_empty
  end

  it "publica na DLQ e marca na última tentativa com falha transitória" do
    stub_request(:post, url).to_return(status: 503)
    allow(consumer).to receive(:attempt).and_return(10)
    produce

    consumer.consume

    expect(consumed_up_to).to eq(1)
    expect(dead_letters.size).to eq(1)
    expect(dead_letters.first[:headers]).to include("dlq_reason" => "retries_exhausted", "dlq_status" => "503")
  end

  it "publica na DLQ sem dlq_status quando o Core não responde na última tentativa" do
    stub_request(:post, url).to_raise(Errno::ECONNREFUSED)
    allow(consumer).to receive(:attempt).and_return(10)
    produce

    consumer.consume

    expect(dead_letters.first[:headers]).to include("dlq_reason" => "retries_exhausted")
    expect(dead_letters.first[:headers]).not_to have_key("dlq_status")
  end

  it "lança e não marca quando a publicação na DLQ falha" do
    stub_request(:post, url).to_return(status: 422)
    produce
    allow(consumer.producer).to receive(:produce_sync).and_raise(WaterDrop::Errors::ProduceError, "msg_timed_out")

    expect { consumer.consume }.to raise_error(WaterDrop::Errors::ProduceError)
    expect(consumed_up_to).to eq(0)
  end

  it "marca cada mensagem do lote e para na que falha de forma transitória" do
    stub_request(:post, url).to_return({ status: 200 }, { status: 503 })
    allow(consumer).to receive(:attempt).and_return(1)
    produce(offset: 0)
    produce(offset: 1)

    expect { consumer.consume }.to raise_error(Broker::TransientError)
    expect(consumed_up_to).to eq(1)
  end
end

require "broker_helper"

RSpec.describe Broker::CoreClient, broker: true do
  let(:url) { broker_env("CORE_ACTIONS_URL") }
  let(:body) { contract_example("action", "reply") }
  let(:idempotency_key) { Contract::IdempotencyKey.for_action(JSON.parse(body)) }
  let(:traceparent) { "00-4bf92f3577b34da6a3ce929d0e0e4736-7d3e8a1c9b2f4e60-01" }

  def deliver
    described_class.deliver(body: body, idempotency_key: idempotency_key, traceparent: traceparent)
  end

  def header_of(request, name)
    request.headers.find { |key, _| key.casecmp?(name) }&.last
  end

  it "envia o corpo sem alteração, assinado com AGENT_ACTIONS_SECRET, com Idempotency-Key e traceparent" do
    stub_request(:post, url).to_return(status: 200, body: '{"status":"accepted"}')

    deliver

    expect(WebMock).to(have_requested(:post, url).with do |request|
      Contract::Signature.verify!(
        secret: broker_env("AGENT_ACTIONS_SECRET"),
        timestamp: header_of(request, "X-Cloudesk-Timestamp"),
        signature: header_of(request, "X-Cloudesk-Signature"),
        method: "POST", path: "/api/v1/agent/actions", body: request.body
      )
      request.body == body &&
        header_of(request, "Idempotency-Key") == idempotency_key &&
        header_of(request, "traceparent") == traceparent &&
        header_of(request, "Content-Type") == "application/json"
    end)
  end

  it "trata 200 como resultado final" do
    stub_request(:post, url).to_return(status: 200, body: '{"status":"accepted"}')

    result = deliver

    expect(result).to be_final
    expect(result.status).to eq(200)
  end

  %w[stale rejected].each do |status|
    it "trata 409 #{status} como resultado final" do
      stub_request(:post, url).to_return(status: 409, body: JSON.generate("status" => status))

      result = deliver

      expect(result).to be_final
      expect(result.status).to eq(409)
    end
  end

  [ 400, 401, 404, 422 ].each do |status|
    it "manda #{status} para a DLQ" do
      stub_request(:post, url).to_return(status: status, body: '{"status":"error"}')

      result = deliver

      expect(result).to be_dead_letter
      expect(result.status).to eq(status)
    end
  end

  [ 408, 429, 500, 502, 503 ].each do |status|
    it "lança TransientError em #{status}" do
      stub_request(:post, url).to_return(status: status)

      expect { deliver }.to raise_error(Broker::TransientError) { |error| expect(error.status).to eq(status) }
    end
  end

  [ Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError ].each do |failure|
    it "lança TransientError sem status no erro de rede #{failure}" do
      stub_request(:post, url).to_raise(failure)

      expect { deliver }.to raise_error(Broker::TransientError) { |error| expect(error.status).to be_nil }
    end
  end
end

require "rails_helper"

RSpec.describe Audit::EventEnvelope do
  let(:traceparent) { TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01") }
  let(:received_at) { Time.utc(2026, 11, 13, 14, 2, 11.482r) }
  let(:attributes) do
    {
      type: "message.created",
      brand: "infinitepay",
      conversation_id: "019a8f3e-0000-7000-8000-000000000001",
      sequence: 7,
      received_at: received_at,
      payload: { message: { author: "customer", channel: "whatsapp", text: "Meu repasse de ontem não caiu" } },
      traceparent: traceparent
    }
  end

  it "gera um event_id UUID v7" do
    expect(described_class.build(**attributes).event_id).to match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/)
  end

  it "serializa os oito campos, com received_at em ISO 8601 UTC com milissegundos" do
    envelope = described_class.build(**attributes)

    expect(envelope.to_h).to eq(
      "event_id" => envelope.event_id,
      "type" => "message.created",
      "brand" => "infinitepay",
      "conversation_id" => "019a8f3e-0000-7000-8000-000000000001",
      "sequence" => 7,
      "received_at" => "2026-11-13T14:02:11.482Z",
      "payload" => { "message" => { "author" => "customer", "channel" => "whatsapp",
                                    "text" => "Meu repasse de ontem não caiu" } },
      "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    )
  end

  it "é reconstruído a partir da forma serializada" do
    envelope = described_class.build(**attributes)

    expect(described_class.from_h(envelope.to_h)).to eq(envelope)
    expect(described_class.from_h(JSON.parse(envelope.to_h.to_json)).to_h).to eq(envelope.to_h)
  end

  it "aceita evento sem conversa e sem sequência" do
    envelope = described_class.build(**attributes.merge(conversation_id: nil, sequence: nil))

    expect(envelope.to_h).to include("conversation_id" => nil, "sequence" => nil)
  end

  it "recusa envelope sem type, brand, received_at ou traceparent" do
    %i[type brand received_at traceparent].each do |field|
      expect { described_class.build(**attributes.merge(field => nil)) }.to raise_error(ArgumentError)
    end
  end
end

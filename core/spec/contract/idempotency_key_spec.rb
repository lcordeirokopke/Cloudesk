require "rails_helper"

RSpec.describe Contract::IdempotencyKey do
  vectors = JSON.parse(Contract::Schemas.root.join("idempotency-key-vectors.json").read).fetch("vectors")

  vectors.each do |vector|
    it "deriva a chave da ação #{vector.fetch('type')}" do
      key = described_class.derive(inbound_event_id: vector.fetch("inbound_event_id"), type: vector.fetch("type"))

      expect(key).to eq(vector.fetch("idempotency_key"))
    end
  end

  it "produz a mesma chave para o mesmo evento e o mesmo tipo de ação" do
    action = JSON.parse(Contract::Schemas.root.join("examples/action/valid/reply.json").read)

    expect(described_class.for_action(action)).to eq(described_class.for_action(action.deep_dup))
  end

  it "produz chaves distintas para tipos de ação distintos do mesmo evento" do
    keys = described_class::ACTION_TYPES.map { |type| described_class.derive(inbound_event_id: "e", type: type) }

    expect(keys.uniq.size).to eq(4)
  end

  it "recusa tipo de ação desconhecido e evento ausente" do
    expect { described_class.derive(inbound_event_id: "e", type: "transfer") }.to raise_error(ArgumentError)
    expect { described_class.derive(inbound_event_id: nil, type: "reply") }.to raise_error(ArgumentError)
  end

  it "cabe na tabela de eventos processados, uma vez por marca" do
    key = described_class.derive(inbound_event_id: SecureRandom.uuid_v7, type: "reply")

    Tenancy.with_brand(infinitepay) do
      expect(ProcessedEvent.record(idempotency_key: key, result: { status: "accepted" })).to be(true)
      expect(ProcessedEvent.record(idempotency_key: key, result: { status: "accepted" })).to be(false)
    end
  end
end

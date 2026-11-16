require "rails_helper"

RSpec.describe ProcessedEvent do
  let(:key) { "0198f3a2-7c1e-7b7a-9d0e-5a1c2b3d4e5f:reply" }

  it "a segunda inserção da mesma Idempotency-Key na mesma marca é rejeitada pelo índice único" do
    Tenancy.with_brand(infinitepay) do
      described_class.create!(idempotency_key: key, result: { "status" => 201 })

      expect do
        in_savepoint { described_class.create!(idempotency_key: key, result: { "status" => 201 }) }
      end.to raise_error(ActiveRecord::RecordNotUnique, /index_processed_events_on_brand_id_and_idempotency_key/)

      expect(described_class.where(idempotency_key: key).count).to eq(1)
    end
  end

  it "a mesma chave é aceita em outra marca" do
    Tenancy.with_brand(infinitepay) { described_class.create!(idempotency_key: key) }

    Tenancy.with_brand(jim) do
      expect { described_class.create!(idempotency_key: key) }.not_to raise_error
    end
  end

  describe ".record" do
    it "insere na primeira vez e guarda o resultado da primeira ação" do
      Tenancy.with_brand(infinitepay) do
        expect(described_class.record(idempotency_key: key, result: { "status" => 201 })).to be(true)
        expect(described_class.record(idempotency_key: key, result: { "status" => 500 })).to be(false)

        expect(described_class.find_by!(idempotency_key: key).result).to eq("status" => 201)
      end
    end
  end
end

require "rails_helper"

RSpec.describe Routing::Queue do
  let(:brand) { infinitepay }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def queue(name)
    Routing::Queue.find_by!(name: name)
  end

  it "aceita uma fila humana da marca como fila de escalação" do
    in_brand do
      record = queue("ip-suporte-geral")
      record.escalation_queue = queue("ip-financeiro")

      expect(record).to be_valid
    end
  end

  it "recusa fila de escalação com atendente inicial IA" do
    in_brand do
      record = queue("ip-financeiro")
      record.escalation_queue = queue("ip-suporte-geral")

      expect(record).not_to be_valid
      expect(record.errors[:escalation_queue]).to include("deve ser uma fila humana da marca")
    end
  end

  it "recusa a própria fila como fila de escalação" do
    in_brand do
      record = queue("ip-financeiro")
      record.escalation_queue_id = record.id

      expect(record).not_to be_valid
      expect(record.errors[:escalation_queue]).to include("deve ser diferente da própria fila")
    end
  end

  it "o banco recusa fila de escalação de outra marca" do
    other = Tenancy.with_brand(jim) { queue("jim-finance").id }

    expect_database_error(/foreign key/i) do
      in_brand { Routing::Queue.where(name: "ip-suporte-geral").update_all(escalation_queue_id: other) }
    end
  end
end

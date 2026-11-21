require "rails_helper"

RSpec.describe "Esquema de domínio" do
  let(:connection) { ApplicationRecord.lease_connection }
  let(:domain_tables) { DatabaseHelpers::DOMAIN_MODELS.map(&:table_name) }

  it "usa uuidv7() como default das chaves primárias" do
    (domain_tables + %w[brands]).each do |table|
      id = connection.columns(table).find { |column| column.name == "id" }

      expect(id.sql_type).to eq("uuid"), table
      expect(id.default_function).to eq("uuidv7()"), table
    end
  end

  it "inclui brand_id em todo índice único de domínio" do
    domain_tables.each do |table|
      connection.indexes(table).select(&:unique).each do |index|
        expect(index.columns).to include("brand_id"), "#{table}.#{index.name}"
      end
    end
  end

  it "dá ao papel da aplicação as permissões previstas" do
    grants = connection.select_rows(<<~SQL).group_by(&:first).transform_values { |rows| rows.map(&:last).sort }
      SELECT table_name, privilege_type FROM information_schema.role_table_grants
       WHERE grantee = current_user AND table_schema = 'public'
    SQL

    (domain_tables - %w[audit_events]).each do |table|
      expect(grants[table]).to eq(%w[DELETE INSERT SELECT UPDATE]), table
    end
    expect(grants["audit_events"]).to eq(%w[INSERT SELECT])
    expect(grants["brands"]).to eq(%w[SELECT])
  end

  it "o papel da aplicação não grava em brands" do
    expect_database_error(/permission denied/) do
      Brand.create!(slug: "outra", name: "Outra", locale: "pt-BR")
    end
  end

  describe Routing::Queue do
    it "usa a tabela queues e aponta para a fila de transbordo" do
      Tenancy.with_brand(infinitepay) do
        queue = described_class.find_by!(name: "ip-financeiro-prioritaria")

        expect(described_class.table_name).to eq("queues")
        expect(queue.overflow_queue.name).to eq("ip-financeiro")
        expect(queue.first_attendant).to eq("ai")
      end
    end
  end

  describe RoutingRule do
    it "lê a condição e o resultado, e cada versão é imutável" do
      Tenancy.with_brand(infinitepay) do
        rule = described_class.order(:position).first!

        expect(rule.when).to include("priority" => "high", "segment" => "alto_tpv")
        expect(rule.then).to include("queue" => "ip-urgente", "priority" => 100)
        expect { rule.update!(position: 9) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      end
    end

    it "grava a nova versão como outra linha, com o mesmo rule_id" do
      Tenancy.with_brand(infinitepay) do
        rule = described_class.order(:position).first!
        next_version = described_class.create!(
          rule_id: rule.rule_id, version: rule.version + 1, name: rule.name, position: rule.position,
          when: rule.when, then: rule.then.merge("priority" => 95)
        )

        expect(described_class.where(rule_id: rule.rule_id).order(:version).pluck(:version)).to eq([ 1, 2 ])
        expect(next_version.then["priority"]).to eq(95)
      end
    end
  end
end

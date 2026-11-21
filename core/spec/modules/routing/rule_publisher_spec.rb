require "rails_helper"

RSpec.describe Routing::RulePublisher do
  let(:brand) { infinitepay }
  let(:attributes) do
    { name: "Chat · Taxas", position: 5, when: { brand: "infinitepay", channel: "chat", category: "taxas" },
      then: { queue: "ip-financeiro", priority: 40 } }
  end

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def published_event(rule)
    in_brand { AuditEvent.find_by!(action: "routing_rule.published", target_id: rule.id) }
  end

  def rule_named(name)
    in_brand { RoutingRule.latest_versions.find_by!(name: name) }
  end

  def counts
    in_brand { { rules: RoutingRule.count, audit_events: AuditEvent.count } }
  end

  describe "create" do
    it "grava a versão 1, ativa, com routing_rule.published, autor e diff" do
      rule = described_class.create(brand: brand, attributes: attributes)

      expect(rule).to have_attributes(version: 1, name: "Chat · Taxas", position: 5, active: true)
      expect(rule["when"]).to eq("brand" => "infinitepay", "channel" => "chat", "category" => "taxas")
      event = published_event(rule)
      expect(event).to have_attributes(actor_type: "operator", actor_id: nil, target_type: "RoutingRule",
                                       routing_rule_id: rule.id, rule_version: 1, before: nil)
      expect(event.after).to include("name" => "Chat · Taxas", "active" => true)
      payload = event.payload.fetch("payload")
      expect(payload).to include("operation" => "create", "rule_id" => rule.rule_id, "version" => 1)
      expect(payload["diff"].keys).to match_array(%w[name position when then active])
      expect(payload["diff"]["name"]).to eq("before" => nil, "after" => "Chat · Taxas")
    end

    it "recusa definição inválida sem gravar nada" do
      before_counts = counts

      expect do
        described_class.create(brand: brand, attributes: attributes.merge(when: { humor: "bravo" }))
      end.to raise_error(Routing::RuleDefinition::Invalid, /humor/)
      expect(counts).to eq(before_counts)
    end

    it "recusa atributo desconhecido" do
      expect { described_class.create(brand: brand, attributes: attributes.merge(cor: "azul")) }
        .to raise_error(ArgumentError, /cor/)
    end
  end

  describe "update" do
    it "copia a maior versão, aplica as mudanças e grava version + 1, com before, after e diff" do
      first = described_class.create(brand: brand, attributes: attributes)

      second = described_class.update(brand: brand, rule_id: first.rule_id, attributes: { position: 7 })

      expect(second).to have_attributes(rule_id: first.rule_id, version: 2, position: 7, name: "Chat · Taxas")
      expect(second["then"]).to eq(first["then"])
      in_brand { expect(RoutingRule.where(rule_id: first.rule_id).order(:version).pluck(:version)).to eq([ 1, 2 ]) }
      event = published_event(second)
      expect(event).to have_attributes(routing_rule_id: second.id, rule_version: 2)
      expect(event.before).to include("position" => 5)
      expect(event.after).to include("position" => 7)
      expect(event.payload.dig("payload", "operation")).to eq("update")
      expect(event.payload.dig("payload", "diff")).to eq("position" => { "before" => 5, "after" => 7 })
    end

    it "recusa a operação que não muda a regra" do
      rule = described_class.create(brand: brand, attributes: attributes)

      expect { described_class.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 5 }) }
        .to raise_error(described_class::Unchanged)
    end

    it "regra inexistente levanta RecordNotFound" do
      expect { described_class.update(brand: brand, rule_id: SecureRandom.uuid_v7, attributes: { position: 1 }) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "activate e deactivate" do
    it "gravam nova versão; a regra desativada sai das vigentes e volta ao ser reativada" do
      rule = described_class.create(brand: brand, attributes: attributes)

      deactivated = described_class.deactivate(brand: brand, rule_id: rule.rule_id)
      expect(deactivated).to have_attributes(version: 2, active: false)
      in_brand { expect(RoutingRule.current.pluck(:rule_id)).not_to include(rule.rule_id) }

      activated = described_class.activate(brand: brand, rule_id: rule.rule_id)
      expect(activated).to have_attributes(version: 3, active: true)
      in_brand { expect(RoutingRule.current.pluck(:rule_id)).to include(rule.rule_id) }
      expect(published_event(activated).payload.dig("payload", "diff")).to eq("active" => { "before" => false, "after" => true })
    end
  end

  describe "regra genérica" do
    let(:generic) { rule_named("InfinitePay · Geral") }

    it "recusa a gravação que deixa a marca sem regra genérica ativa, sem gravar nada" do
      before_counts = counts

      expect { described_class.deactivate(brand: brand, rule_id: generic.rule_id) }
        .to raise_error(described_class::NoGenericRule)
      expect { described_class.update(brand: brand, rule_id: generic.rule_id, attributes: { when: { channel: "chat" } }) }
        .to raise_error(described_class::NoGenericRule)
      expect(counts).to eq(before_counts)
    end

    it "aceita desativar a genérica quando outra genérica ativa existe" do
      described_class.create(brand: brand, attributes: attributes.merge(name: "Outra geral", position: 9, when: {}))

      expect(described_class.deactivate(brand: brand, rule_id: generic.rule_id)).to have_attributes(active: false)
    end

    it "cada marca tem a sua regra genérica" do
      jim_generic = Tenancy.with_brand(jim) { RoutingRule.latest_versions.find_by!(name: "JIM · General") }

      expect { described_class.deactivate(brand: jim, rule_id: jim_generic.rule_id) }
        .to raise_error(described_class::NoGenericRule)
    end
  end

  describe "operator_name" do
    it "vai ao payload quando informado, em todas as operações" do
      rule = described_class.create(brand: brand, attributes: attributes, operator_name: "operator-a")
      updated = described_class.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 6 },
                                       operator_name: "operator-b")
      deactivated = described_class.deactivate(brand: brand, rule_id: rule.rule_id, operator_name: "operator-c")
      activated = described_class.activate(brand: brand, rule_id: rule.rule_id, operator_name: "operator-d")

      names = [ rule, updated, deactivated, activated ].map { |version| published_event(version).payload.dig("payload", "operator_name") }
      expect(names).to eq(%w[operator-a operator-b operator-c operator-d])
      expect(published_event(rule)).to have_attributes(actor_type: "operator", actor_id: nil)
    end

    it "sem operator_name, o payload não tem a chave" do
      rule = described_class.create(brand: brand, attributes: attributes)

      expect(published_event(rule).payload.fetch("payload")).not_to have_key("operator_name")
    end
  end

  describe "expected_version" do
    it "igual à maior versão: grava a versão nova" do
      rule = described_class.create(brand: brand, attributes: attributes)

      updated = described_class.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 6 }, expected_version: 1)

      expect(updated.version).to eq(2)
    end

    it "diferente da maior versão: levanta Stale sem gravar nada, também ao ativar e desativar" do
      rule = described_class.create(brand: brand, attributes: attributes)
      described_class.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 6 })
      before_counts = counts

      expect do
        described_class.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 7 }, expected_version: 1)
      end.to raise_error(described_class::Stale)
      expect { described_class.deactivate(brand: brand, rule_id: rule.rule_id, expected_version: "1") }
        .to raise_error(described_class::Stale)
      expect(counts).to eq(before_counts)
      in_brand { expect(RoutingRule.where(rule_id: rule.rule_id).maximum(:version)).to eq(2) }
    end
  end

  describe "trava" do
    it "toda gravação roda sob a Routing::RoutingLock da marca" do
      expect(Routing::RoutingLock).to receive(:acquire).with(brand).at_least(:once).and_call_original

      described_class.create(brand: brand, attributes: attributes)
    end
  end
end

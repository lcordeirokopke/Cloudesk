require "rails_helper"

RSpec.describe Admin::RuleForm do
  let(:brand) { infinitepay }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def rule(name, target = brand)
    in_brand(target) { RoutingRule.latest_versions.find_by!(name: name) }
  end

  def params(when_clause: {}, **then_clause)
    { name: "Nova", position: "7", when: when_clause,
      then: { queue: "ip-financeiro", priority: "40", sla_minutes: "", first_attendant: "" }.merge(then_clause) }
  end

  # Campos que o formulário envia para a regra, como o navegador: cada valor marcado da dimensão,
  # o horário marcado e os campos do then, todos texto.
  def submitted(form)
    {
      name: form.name, position: form.position.to_s,
      when: described_class::DIMENSIONS.to_h { |dimension| [ dimension, form.selected(dimension) ] }.merge("hours" => form.hours),
      then: form.then_values
    }
  end

  describe "conversão" do
    it "uma opção vira texto, várias viram lista e nenhuma tira a chave; brand é sempre o slug" do
      form = described_class.from_params(
        brand: brand, params: params(when_clause: { channel: [ "", "chat" ], category: %w[taxas repasse], segment: [ "" ] })
      )

      expect(form.to_attributes["when"]).to eq("brand" => "infinitepay", "channel" => "chat", "category" => %w[repasse taxas])
    end

    it "posição e prioridade viram inteiros; SLA vazio e atendente da fila saem do then" do
      attributes = described_class.from_params(brand: brand, params: params).to_attributes

      expect(attributes).to include("name" => "Nova", "position" => 7)
      expect(attributes["then"]).to eq("queue" => "ip-financeiro", "priority" => 40)
    end

    it "SLA e atendente preenchidos ficam no then" do
      attributes = described_class.from_params(brand: brand, params: params(sla_minutes: "30", first_attendant: "human"))
                                  .to_attributes

      expect(attributes["then"]).to eq("queue" => "ip-financeiro", "priority" => 40, "sla_minutes" => 30,
                                       "first_attendant" => "human")
    end

    it "hours vazio não condiciona; business vira texto" do
      expect(described_class.from_params(brand: brand, params: params(when_clause: { hours: "" })).to_attributes["when"])
        .to eq("brand" => "infinitepay")
      expect(described_class.from_params(brand: brand, params: params(when_clause: { hours: "business" })).to_attributes["when"])
        .to include("hours" => "business")
    end

    it "texto que não é número passa adiante para a validação recusar" do
      attributes = described_class.from_params(brand: brand, params: params(priority: "alta")).to_attributes

      expect(attributes["then"]["priority"]).to eq("alta")
    end
  end

  describe "opções" do
    it "vêm de Routing::Dimensions" do
      form = described_class.from_rule(brand: brand)

      expect(form.options("segment")).to eq(%w[alto_tpv medio_tpv baixo_tpv])
      expect(form.options("category")).to eq(Routing::Classifier.categories(brand))
    end

    it "valor gravado fora da lista aparece marcado e é preservado" do
      vip = Routing::RulePublisher.create(
        brand: brand, attributes: { name: "VIP", position: 3, when: { brand: "infinitepay", segment: "vip" },
                                    then: { queue: "ip-urgente", priority: 99 } }
      )
      form = described_class.from_rule(brand: brand, rule: vip)

      expect(form.options("segment")).to eq(%w[alto_tpv medio_tpv baixo_tpv vip])
      expect(form.selected("segment")).to eq(%w[vip])
      expect(form.outside?("segment", "vip")).to be(true)

      unchanged = described_class.from_params(brand: brand, params: submitted(form), rule: vip)
      expect { Routing::RulePublisher.update(brand: brand, rule_id: vip.rule_id, attributes: unchanged.to_attributes) }
        .to raise_error(Routing::RulePublisher::Unchanged)

      changed = described_class.from_params(brand: brand, params: submitted(form).merge(position: "4"), rule: vip)
      updated = Routing::RulePublisher.update(brand: brand, rule_id: vip.rule_id, attributes: changed.to_attributes)
      expect(updated["when"]).to eq("brand" => "infinitepay", "segment" => "vip")
      expect(updated.position).to eq(4)
    end

    it "na lista, os valores gravados mantêm a ordem gravada e os novos seguem a ordem das opções" do
      form = described_class.from_params(
        brand: brand, rule: rule("InfinitePay · Geral · Médio e alto volume"),
        params: params(when_clause: { segment: %w[alto_tpv medio_tpv baixo_tpv] })
      )

      expect(form.selected("segment")).to eq(%w[medio_tpv alto_tpv baixo_tpv])
    end
  end

  describe "ida e volta" do
    it "cada regra das seeds, enviada sem mudança, levanta Unchanged" do
      [ infinitepay, jim ].each do |target|
        rules = in_brand(target) { RoutingRule.latest_versions.order(:position).to_a }
        expect(rules.size).to eq(13)

        rules.each do |seeded|
          form = described_class.from_params(
            brand: target, params: submitted(described_class.from_rule(brand: target, rule: seeded)), rule: seeded
          )
          expect { Routing::RulePublisher.update(brand: target, rule_id: seeded.rule_id, attributes: form.to_attributes) }
            .to raise_error(Routing::RulePublisher::Unchanged), seeded.name
        end
      end
    end
  end
end

require "rails_helper"

RSpec.describe Routing::Matcher do
  let(:business_hours) do
    { "weekdays" => [ 1, 2, 3, 4, 5 ], "from" => "08:00", "to" => "20:00", "timezone" => "America/Sao_Paulo" }
  end
  # Segunda-feira, 10:00 em São Paulo.
  let(:monday_morning) { Time.utc(2026, 11, 16, 13, 0) }
  let(:facts) do
    { brand: "infinitepay", channel: "whatsapp", category: "repasse", priority: "normal", segment: "alto_tpv",
      language: "pt-BR", received_at: monday_morning }
  end

  def rule(name, position, when_clause, rule_id: name, queue: "fila")
    { "id" => "#{name}-id", "rule_id" => rule_id, "version" => 1, "name" => name, "position" => position,
      "when" => when_clause, "then" => { "queue" => queue, "priority" => 1 } }
  end

  def first_match(rules, facts = self.facts, hours: business_hours)
    described_class.new(rules, business_hours_for: ->(_queue) { hours }).first_match(facts)&.fetch("name")
  end

  describe "ordem de avaliação" do
    it "a primeira regra por position vence, qualquer que seja a ordem da lista" do
      rules = [ rule("geral", 3, {}), rule("repasse", 2, { "category" => "repasse" }),
                rule("repasse alto", 1, { "category" => "repasse", "segment" => "alto_tpv" }) ]

      expect(first_match(rules)).to eq("repasse alto")
      expect(first_match(rules, facts.merge(segment: "baixo_tpv"))).to eq("repasse")
      expect(first_match(rules, facts.merge(category: "taxas"))).to eq("geral")
    end

    it "no empate de position, vence o menor rule_id" do
      rules = [ rule("b", 1, {}, rule_id: "0002"), rule("a", 1, {}, rule_id: "0001") ]

      expect(first_match(rules)).to eq("a")
    end

    it "sem regra que case, devolve nil" do
      expect(first_match([ rule("chat", 1, { "channel" => "chat" }) ])).to be_nil
    end
  end

  describe "condições" do
    it "todas as chaves precisam casar" do
      rules = [ rule("dupla", 1, { "category" => "repasse", "language" => "en-US" }) ]

      expect(first_match(rules)).to be_nil
      expect(first_match(rules, facts.merge(language: "en-US"))).to eq("dupla")
    end

    it "lista casa com qualquer item" do
      rules = [ rule("canais", 1, { "channel" => %w[chat whatsapp] }) ]

      expect(first_match(rules)).to eq("canais")
      expect(first_match(rules, facts.merge(channel: "email"))).to be_nil
    end

    it "fato vazio não casa" do
      rules = [ rule("segmento", 1, { "segment" => "alto_tpv" }), rule("categoria", 2, { "category" => "repasse" }) ]

      expect(first_match(rules, facts.merge(segment: nil, category: nil))).to be_nil
    end

    it "priority compara com a urgência" do
      rules = [ rule("urgente", 1, { "priority" => "high" }), rule("geral", 2, {}) ]

      expect(first_match(rules, facts.merge(priority: "high"))).to eq("urgente")
      expect(first_match(rules)).to eq("geral")
    end

    it "hours confere o received_at no horário da equipe da fila de destino" do
      rules = [ rule("comercial", 1, { "hours" => "business" }), rule("fora", 2, { "hours" => "off_hours" }) ]
      saturday = Time.utc(2026, 11, 21, 13, 0)

      expect(first_match(rules)).to eq("comercial")
      expect(first_match(rules, facts.merge(received_at: saturday))).to eq("fora")
    end

    it "hours com horário da equipe ausente conta como off_hours" do
      rules = [ rule("comercial", 1, { "hours" => "business" }), rule("fora", 2, { "hours" => "off_hours" }) ]

      expect(first_match(rules, hours: nil)).to eq("fora")
    end
  end

  # Regras gravadas no banco, lidas por Routing::CompiledRules como no roteamento.
  describe "com as regras vigentes da marca" do
    let(:brand) { infinitepay }

    def match_in_brand(facts)
      Tenancy.with_brand(brand) do
        described_class.new(Routing::CompiledRules.compile, business_hours_for: ->(_queue) { nil }).first_match(facts)
      end
    end

    def create_rule(**attributes)
      Tenancy.with_brand(brand) do
        RoutingRule.create!(then: { "queue" => "ip-financeiro", "priority" => 1 }, **attributes)
      end
    end

    it "usa as regras das seeds em ordem" do
      expect(match_in_brand(facts)["name"]).to eq("InfinitePay · Repasse · Alto volume")
      expect(match_in_brand(facts.merge(segment: "medio_tpv"))["name"]).to eq("InfinitePay · Repasse")
      expect(match_in_brand(facts.merge(category: nil))["name"]).to eq("InfinitePay · Geral · Médio e alto volume")
      expect(match_in_brand(facts.merge(category: nil, segment: "baixo_tpv"))["name"]).to eq("InfinitePay · Geral")
    end

    it "só a maior versão de cada regra participa" do
      first = create_rule(name: "chat v1", position: 0, when: { "channel" => "chat" })
      create_rule(rule_id: first.rule_id, version: 2, name: "chat v2", position: 0, when: { "channel" => "email" })

      expect(match_in_brand(facts.merge(channel: "chat"))["name"]).to eq("InfinitePay · Repasse · Alto volume")
      expect(match_in_brand(facts.merge(channel: "email"))).to include("name" => "chat v2", "version" => 2)
    end

    it "regra inativa é ignorada, e a versão inativa mais nova esconde a ativa anterior" do
      first = create_rule(name: "chat", position: 0, when: { "channel" => "chat" })
      create_rule(rule_id: first.rule_id, version: 2, name: "chat", position: 0, when: { "channel" => "chat" }, active: false)
      create_rule(name: "email inativa", position: 0, when: { "channel" => "email" }, active: false)

      expect(match_in_brand(facts.merge(channel: "chat"))["name"]).to eq("InfinitePay · Repasse · Alto volume")
      expect(match_in_brand(facts.merge(channel: "email"))["name"]).to eq("InfinitePay · Repasse · Alto volume")
    end
  end
end

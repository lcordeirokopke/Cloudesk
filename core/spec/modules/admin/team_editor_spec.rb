require "rails_helper"

RSpec.describe Admin::TeamEditor do
  let(:brand) { infinitepay }
  let(:valid_hours) { { "weekdays" => [ 1, 2, 3 ], "from" => "09:00", "to" => "18:00", "timezone" => "America/Sao_Paulo" } }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def team(name, target = brand)
    in_brand(target) { Team.find_by!(name: name) }
  end

  def create(attributes, target = brand)
    described_class.create(brand: target, attributes: attributes, operator_name: "operator-a")
  end

  def edit(team, attributes, expected: Admin::Editor.version_of(team))
    described_class.update(brand: brand, team_id: team.id, attributes: attributes, expected_updated_at: expected,
                           operator_name: "operator-b")
  end

  def events(record, action)
    in_brand { AuditEvent.where(target_type: "Team", target_id: record.id, action: action).to_a }
  end

  describe "create" do
    it "grava a equipe com team.created, skills limpas e horário" do
      created = create(name: "Cobrança", skills: [ " repasse ", "", "repasse", "taxas" ], business_hours: valid_hours)

      expect(created).to have_attributes(name: "Cobrança", skills: %w[repasse taxas], business_hours: valid_hours)
      event = events(created, "team.created").sole
      expect(event).to have_attributes(actor_type: "operator", actor_id: nil, before: nil)
      expect(event.payload.dig("payload", "operator_name")).to eq("operator-a")
      expect(event.payload.dig("payload", "diff", "business_hours")).to eq("before" => nil, "after" => valid_hours)
    end

    it "aceita horário vazio" do
      expect(create(name: "Sem horário", business_hours: {}).business_hours).to eq({})
    end

    it "recusa horário inválido" do
      expect { create(name: "Inválida", business_hours: valid_hours.merge("to" => "08:00")) }
        .to raise_error(Admin::Invalid, /horário comercial é inválido/)
    end

    it "recusa nome repetido na marca; o mesmo nome em outra marca passa" do
      expect { create(name: "Financeiro") }.to raise_error(Admin::Invalid, /já existe equipe com o nome Financeiro/)

      expect(create({ name: "Financeiro" }, jim).brand_id).to eq(jim.id)
    end
  end

  describe "update" do
    it "grava team.updated com o diff" do
      target = team("Suporte Técnico")

      edit(target, { skills: %w[maquininha app pix] })

      event = events(target, "team.updated").sole
      expect(event.payload.dig("payload", "diff")).to eq(
        "skills" => { "before" => %w[maquininha app], "after" => %w[maquininha app pix] }
      )
      expect(event.payload.dig("payload", "operator_name")).to eq("operator-b")
    end

    it "edição sem mudança levanta Unchanged" do
      target = team("Suporte Técnico")

      expect { edit(target, { name: "Suporte Técnico", skills: %w[maquininha app] }) }.to raise_error(Admin::Unchanged)
    end

    it "updated_at diferente do lido levanta Stale e nada é gravado" do
      target = team("Suporte Técnico")
      stale = Admin::Editor.version_of(target)
      edit(target, { skills: %w[maquininha] })

      expect { edit(target, { skills: %w[app] }, expected: stale) }.to raise_error(Admin::Stale)
      expect(team("Suporte Técnico").skills).to eq(%w[maquininha])
    end
  end

  describe "horário com regra hours" do
    # Suporte Técnico é a equipe de ip-maquininha, destino de regras ativas com when.hours.
    it "recusa deixar vazio ou inválido o horário da equipe com regra hours ativa" do
      target = team("Suporte Técnico")

      expect { edit(target, { business_hours: {} }) }.to raise_error(Admin::Invalid, /InfinitePay · Maquininha/)
      expect { edit(target, { business_hours: valid_hours.merge("timezone" => "Lugar/Nenhum") }) }
        .to raise_error(Admin::Invalid, /inválido/)
      expect(events(target, "team.updated")).to be_empty
    end

    it "aceita trocar por outro horário válido" do
      target = team("Suporte Técnico")

      expect(edit(target, { business_hours: valid_hours }).business_hours).to eq(valid_hours)
    end

    it "sem regra hours, deixar vazio passa; inválido continua recusado" do
      target = team("Financeiro")

      expect { edit(target, { business_hours: { "weekdays" => [] } }) }.to raise_error(Admin::Invalid, /inválido/)
      expect(edit(target, { business_hours: {} }).business_hours).to eq({})
    end

    it "regra hours inativa não bloqueia" do
      target = team("Suporte Técnico")
      [ "InfinitePay · Maquininha", "InfinitePay · Maquininha · Fora do horário" ].each do |name|
        rule_id = in_brand { RoutingRule.latest_versions.find_by!(name: name).rule_id }
        Routing::RulePublisher.deactivate(brand: brand, rule_id: rule_id)
      end

      expect(edit(target, { business_hours: {} }).business_hours).to eq({})
    end
  end
end

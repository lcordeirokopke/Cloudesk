require "rails_helper"

RSpec.describe Admin::AttendantEditor do
  let(:brand) { infinitepay }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def team(name)
    in_brand { Team.find_by!(name: name) }
  end

  def analyst
    in_brand { Attendant.where(kind: "human").order(:name).first! }
  end

  def edit(attendant, attributes, expected: Admin::Editor.version_of(attendant))
    described_class.update(brand: brand, attendant_id: attendant.id, attributes: attributes, expected_updated_at: expected,
                           operator_name: "operator-a")
  end

  def events(record, action)
    in_brand { AuditEvent.where(target_type: "Attendant", target_id: record.id, action: action).to_a }
  end

  it "cria sempre analista humano, com attendant.created" do
    created = described_class.create(brand: brand, attributes: { name: "Ana Teste", team_id: team("Financeiro").id,
                                                                 capacity: 3, skills: %w[repasse] },
                                     operator_name: "operator-a")

    expect(created).to have_attributes(kind: "human", name: "Ana Teste", capacity: 3, skills: %w[repasse])
    event = events(created, "attendant.created").sole
    expect(event).to have_attributes(actor_type: "operator", actor_id: nil)
    expect(event.after).to include("name" => "Ana Teste", "capacity" => 3)
    expect(event.payload.dig("payload", "operator_name")).to eq("operator-a")
  end

  it "cria analista sem equipe" do
    created = described_class.create(brand: brand, attributes: { name: "Sem Equipe", capacity: 2 }, operator_name: "op")

    expect(created.team_id).to be_nil
  end

  it "kind nos atributos levanta ArgumentError" do
    expect do
      described_class.create(brand: brand, attributes: { name: "IA", capacity: 1, kind: "ai" }, operator_name: "op")
    end.to raise_error(ArgumentError, /kind/)
  end

  it "recusa capacidade não inteira ou menor que 1" do
    [ 0, "1.5", nil ].each do |capacity|
      expect do
        described_class.create(brand: brand, attributes: { name: "X", capacity: capacity }, operator_name: "op")
      end.to raise_error(Admin::Invalid)
    end
  end

  it "edita capacidade e equipe com attendant.updated e o diff" do
    target = analyst
    other_team = target.team_id == team("Financeiro").id ? team("Suporte Técnico") : team("Financeiro")

    edit(target, { capacity: 8, team_id: other_team.id })

    event = events(target, "attendant.updated").sole
    expect(event.payload.dig("payload", "diff")).to eq(
      "capacity" => { "before" => 5, "after" => 8 }, "team_id" => { "before" => target.team_id, "after" => other_team.id }
    )
  end

  it "recusa editar o atendente IA, sem mudar o first_ai" do
    ai = in_brand { Attendant.first_ai }

    expect { edit(ai, { name: "Outro nome" }) }.to raise_error(Admin::NotAllowed)
    expect(in_brand { Attendant.first_ai }).to have_attributes(id: ai.id, name: ai.name)
    expect(events(ai, "attendant.updated")).to be_empty
  end

  it "updated_at diferente do lido levanta Stale" do
    target = analyst
    stale = Admin::Editor.version_of(target)
    edit(target, { capacity: 6 })

    expect { edit(target, { capacity: 7 }, expected: stale) }.to raise_error(Admin::Stale)
  end

  it "edição sem mudança levanta Unchanged" do
    expect { edit(analyst, { capacity: 5 }) }.to raise_error(Admin::Unchanged)
  end
end

require "rails_helper"

RSpec.describe Routing::RuleDefinition do
  let(:brand) { infinitepay }
  let(:valid_then) { { "queue" => "ip-financeiro", "priority" => 50 } }

  def errors_for(when_clause, then_clause = valid_then)
    Tenancy.with_brand(brand) do
      described_class.new(brand: brand, when_clause: when_clause, then_clause: then_clause).errors
    end
  end

  it "aceita todas as chaves de when, com texto ou lista de textos" do
    when_clause = {
      "brand" => "infinitepay", "channel" => %w[chat whatsapp], "category" => "repasse", "priority" => "high",
      "segment" => "alto_tpv", "language" => "pt-BR", "hours" => "business"
    }

    expect(errors_for(when_clause, valid_then.merge("sla_minutes" => 30, "first_attendant" => "ai"))).to eq([])
  end

  it "aceita when vazio" do
    expect(errors_for({})).to eq([])
  end

  it "recusa chave desconhecida em when e em then" do
    expect(errors_for({ "humor" => "bravo" }, valid_then.merge("cor" => "azul"))).to contain_exactly(
      "when tem chaves desconhecidas: humor", "then tem chaves desconhecidas: cor"
    )
  end

  it "recusa valor que não é texto nem lista de textos" do
    expect(errors_for({ "category" => 1 })).to eq([ "when.category deve ser um texto ou uma lista de textos" ])
    expect(errors_for({ "category" => [] })).to eq([ "when.category deve ser um texto ou uma lista de textos" ])
    expect(errors_for({ "category" => { "a" => "b" } })).to eq([ "when.category deve ser um texto ou uma lista de textos" ])
  end

  it "recusa brand de outra marca e hours fora de business e off_hours" do
    expect(errors_for({ "brand" => "jim" })).to eq([ "when.brand deve ser infinitepay" ])
    expect(errors_for({ "hours" => "noite" })).to eq([ "when.hours deve ser business ou off_hours" ])
  end

  it "recusa fila inexistente e then incompleto" do
    expect(errors_for({}, { "queue" => "nao-existe", "priority" => 1 })).to eq([ "then.queue não existe na marca: nao-existe" ])
    expect(errors_for({}, {})).to contain_exactly("then.queue deve ser o nome de uma fila", "then.priority deve ser um inteiro")
  end

  it "recusa fila de outra marca" do
    expect(errors_for({}, { "queue" => "jim-finance", "priority" => 1 })).to eq([ "then.queue não existe na marca: jim-finance" ])
  end

  it "recusa sla_minutes não positivo e first_attendant desconhecido" do
    expect(errors_for({}, valid_then.merge("sla_minutes" => 0, "first_attendant" => "robo"))).to contain_exactly(
      "then.sla_minutes deve ser um inteiro positivo", "then.first_attendant deve ser ai ou human"
    )
  end

  it "recusa hours com fila sem equipe ou com equipe sem horário válido" do
    Tenancy.with_brand(brand) do
      Routing::Queue.create!(name: "sem-equipe", sla_minutes: 10, capacity: 10, first_attendant: "human")
      team = Team.create!(name: "Sem horário")
      Routing::Queue.create!(name: "equipe-sem-horario", team: team, sla_minutes: 10, capacity: 10, first_attendant: "human")
    end
    message = "when.hours exige fila de destino com equipe e horário comercial válido"

    expect(errors_for({ "hours" => "business" }, { "queue" => "sem-equipe", "priority" => 1 })).to eq([ message ])
    expect(errors_for({ "hours" => "business" }, { "queue" => "equipe-sem-horario", "priority" => 1 })).to eq([ message ])
  end

  it "validate! levanta Invalid com os erros" do
    expect do
      Tenancy.with_brand(brand) { described_class.validate!(brand: brand, when_clause: { "x" => "y" }, then_clause: valid_then) }
    end.to raise_error(described_class::Invalid, "when tem chaves desconhecidas: x")
  end

  it "regra genérica é when vazio ou só com brand" do
    expect(described_class.generic?({})).to be(true)
    expect(described_class.generic?({ "brand" => "infinitepay" })).to be(true)
    expect(described_class.generic?({ brand: "infinitepay", channel: "chat" })).to be(false)
  end
end

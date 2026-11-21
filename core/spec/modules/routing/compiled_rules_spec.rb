require "rails_helper"

# O ambiente de teste usa null_store; aqui o cache é um MemoryStore durante cada exemplo.
RSpec.describe Routing::CompiledRules do
  let(:brand) { infinitepay }
  let(:store) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(store) }

  def compiled
    Tenancy.with_brand(brand) { described_class.for(brand) }
  end

  def cache_key
    Tenancy.with_brand(brand) { described_class.cache_key(brand) }
  end

  it "devolve as regras vigentes em ordem e preenche o cache" do
    rules = compiled

    expect(rules.map { |rule| rule["name"] }).to eq(
      [
        "InfinitePay · Urgente · Alto volume", "InfinitePay · Urgente", "InfinitePay · Repasse · Alto volume",
        "InfinitePay · Transação · Alto volume", "InfinitePay · Maquininha", "InfinitePay · Transação",
        "InfinitePay · Maquininha · Fora do horário", "InfinitePay · Repasse", "InfinitePay · Taxas",
        "InfinitePay · App", "InfinitePay · Taxas · E-mail", "InfinitePay · Geral · Médio e alto volume",
        "InfinitePay · Geral"
      ]
    )
    expect(rules.first.keys).to eq(%w[id rule_id version name position when then])
    expect(store.read(cache_key)).to eq(rules)
  end

  it "com o cache preenchido, não lê as regras de novo" do
    compiled
    allow(described_class).to receive(:compile).and_call_original

    compiled

    expect(described_class).not_to have_received(:compile)
  end

  it "a chave tem a marca e o maior id de routing_rules" do
    latest_id = Tenancy.with_brand(brand) { RoutingRule.order(id: :desc).pick(:id) }

    expect(cache_key).to eq("routing/rules/#{brand.id}/#{latest_id}")
  end

  it "uma nova versão muda a chave e o resultado" do
    old_key = cache_key
    compiled
    rule_id = Tenancy.with_brand(brand) { RoutingRule.find_by!(name: "InfinitePay · Repasse").rule_id }

    Routing::RulePublisher.update(brand: brand, rule_id: rule_id, attributes: { name: "InfinitePay · Repasse · v2" })

    expect(cache_key).not_to eq(old_key)
    expect(compiled.map { |rule| rule["name"] }).to include("InfinitePay · Repasse · v2")
  end

  it "cada marca tem a sua chave" do
    jim_key = Tenancy.with_brand(jim) { described_class.cache_key(jim) }

    expect(jim_key).to start_with("routing/rules/#{jim.id}/")
    expect(jim_key).not_to eq(cache_key)
  end
end

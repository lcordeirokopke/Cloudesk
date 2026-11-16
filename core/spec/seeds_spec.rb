require "rails_helper"

# As seeds rodam uma vez antes da suíte (spec/support/database_roles.rb). Este teste roda as seeds
# de novo no mesmo banco e compara as contagens.
RSpec.describe "Seeds" do
  self.use_transactional_tests = false

  def counts
    brands = Brand.order(:slug).to_a
    per_brand = brands.to_h do |brand|
      [ brand.slug, Tenancy.with_brand(brand) { DatabaseHelpers::DOMAIN_MODELS.to_h { |model| [ model.name, model.count ] } } ]
    end
    per_brand.merge("brands" => brands.size)
  end

  def identity_values
    Brand.order(:slug).flat_map do |brand|
      Tenancy.with_brand(brand) { ContactIdentity.order(:channel, :value).pluck(:channel, :value) }
    end
  end

  it "criam marcas, equipes, filas, regras, atendentes e lojistas em cada marca" do
    expected = {
      "Team" => 2, "Routing::Queue" => 3, "RoutingRule" => 3, "Attendant" => 5,
      "Contact" => 50, "ContactIdentity" => 150
    }

    expect(counts["brands"]).to eq(2)
    expect(counts["infinitepay"]).to include(expected)
    expect(counts["jim"]).to include(expected)
    expect(infinitepay.locale).to eq("pt-BR")
    expect(jim.locale).to eq("en-US")
  end

  it "rodar de novo no mesmo banco mantém a mesma contagem de registros" do
    before_counts = counts
    before_identities = identity_values

    SeedRunner.run

    expect(counts).to eq(before_counts)
    expect(identity_values).to eq(before_identities)
  end
end

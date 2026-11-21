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
    per_brand.merge("brands" => brands.size, "brand_channels" => BrandChannel.order(:channel, :value).pluck(:channel, :value))
  end

  def identity_values
    Brand.order(:slug).flat_map do |brand|
      Tenancy.with_brand(brand) { ContactIdentity.order(:channel, :value).pluck(:channel, :value) }
    end
  end

  it "criam marcas, canais das marcas, equipes, filas, regras, atendentes e lojistas em cada marca" do
    expected = {
      "Team" => 2, "Routing::Queue" => 3, "RoutingRule" => 3, "Attendant" => 5,
      "Contact" => 50, "ContactIdentity" => 150
    }

    expect(counts["brands"]).to eq(2)
    expect(counts["infinitepay"]).to include(expected)
    expect(counts["jim"]).to include(expected)
    expect(infinitepay.locale).to eq("pt-BR")
    expect(jim.locale).to eq("en-US")
    expect(infinitepay.brand_channels.pluck(:channel, :value)).to contain_exactly(
      [ "whatsapp", "110000000000001" ], [ "whatsapp", "110000000000002" ],
      [ "email", "suporte@infinitepay.test" ], [ "email", "financeiro@infinitepay.test" ]
    )
    expect(jim.brand_channels.pluck(:channel, :value)).to contain_exactly(
      [ "whatsapp", "120000000000001" ], [ "whatsapp", "120000000000002" ],
      [ "email", "support@jim.test" ], [ "email", "payouts@jim.test" ]
    )
  end

  it "gravam as filas de escalação das filas prioritárias" do
    escalations = Brand.order(:slug).flat_map do |brand|
      Tenancy.with_brand(brand) do
        Routing::Queue.includes(:escalation_queue).order(:name).map { |queue| [ queue.name, queue.escalation_queue&.name ] }
      end
    end

    expect(escalations).to contain_exactly(
      [ "ip-financeiro", nil ], [ "ip-financeiro-prioritaria", "ip-financeiro" ], [ "ip-suporte-geral", nil ],
      [ "jim-finance", nil ], [ "jim-finance-priority", "jim-finance" ], [ "jim-general-support", nil ]
    )
  end

  it "gravam os e-mails dos lojistas em ASCII" do
    emails = Brand.order(:slug).flat_map do |brand|
      Tenancy.with_brand(brand) { ContactIdentity.where(channel: "email").pluck(:value) }
    end

    expect(emails.size).to eq(100)
    expect(emails).to all(match(/\A[a-z0-9._-]+@example\.com\z/))
  end

  it "rodar de novo no mesmo banco mantém a mesma contagem de registros" do
    before_counts = counts
    before_identities = identity_values

    SeedRunner.run

    expect(counts).to eq(before_counts)
    expect(identity_values).to eq(before_identities)
    expect(Tenancy.with_brand(infinitepay) { Routing::Queue.find_by!(name: "ip-financeiro-prioritaria").escalation_queue.name })
      .to eq("ip-financeiro")
  end
end

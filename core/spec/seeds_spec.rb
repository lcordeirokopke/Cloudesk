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
      "Team" => 2, "Routing::Queue" => 6, "RoutingRule" => 13, "Attendant" => 5,
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

  it "gravam as filas de escalação" do
    escalations = Brand.order(:slug).flat_map do |brand|
      Tenancy.with_brand(brand) do
        Routing::Queue.includes(:escalation_queue).order(:name).map { |queue| [ queue.name, queue.escalation_queue&.name ] }
      end
    end

    expect(escalations).to contain_exactly(
      [ "ip-financeiro", nil ], [ "ip-financeiro-prioritaria", "ip-financeiro" ], [ "ip-urgente", nil ],
      [ "ip-transacoes", "ip-financeiro" ], [ "ip-maquininha", nil ], [ "ip-suporte-geral", nil ],
      [ "jim-finance", nil ], [ "jim-finance-priority", "jim-finance" ], [ "jim-urgent", nil ],
      [ "jim-transactions", "jim-finance" ], [ "jim-card-reader", nil ], [ "jim-general-support", nil ]
    )
  end

  it "sorteiam os segmentos dos lojistas com peso, todos presentes em cada marca" do
    segments = Brand.order(:slug).to_h do |brand|
      [ brand.slug, Tenancy.with_brand(brand) { Contact.group(:segment).count } ]
    end

    expect(segments["infinitepay"].keys).to contain_exactly("alto_tpv", "medio_tpv", "baixo_tpv")
    expect(segments["jim"].keys).to contain_exactly("high_tpv", "mid_tpv", "low_tpv")
    expect(segments["infinitepay"]["baixo_tpv"]).to be > segments["infinitepay"]["alto_tpv"]
    expect(segments["jim"]["low_tpv"]).to be > segments["jim"]["high_tpv"]
  end

  describe "segmentos" do
    it "são os de config/routing/dimensions.yml em cada marca" do
      Brand.order(:slug).each do |brand|
        seeded = Tenancy.with_brand(brand) { Contact.distinct.pluck(:segment) }
        expect(seeded).to match_array(Routing::Dimensions.config_for(brand.slug).fetch("segments")), brand.slug
      end
    end

    # A conferência roda antes de qualquer gravação; o arquivo é carregado no próprio processo.
    def load_seeds_with(segments)
      allow(Routing::Dimensions).to receive(:config_for).and_call_original
      allow(Routing::Dimensions).to receive(:config_for).with("infinitepay")
                                                       .and_return("segments" => segments, "languages" => %w[pt-BR])
      before_counts = counts
      expect { load Rails.root.join("db/seeds.rb").to_s }.to raise_error(KeyError, yield)
      expect(counts).to eq(before_counts)
    end

    it "recusam segmento das seeds ausente no YAML, sem gravar nada" do
      load_seeds_with(%w[alto_tpv medio_tpv]) { /baixo_tpv/ }
    end

    it "recusam segmento do YAML sem peso nas seeds, sem gravar nada" do
      load_seeds_with(%w[alto_tpv medio_tpv baixo_tpv vip]) { /vip/ }
    end
  end

  describe "regras de roteamento" do
    # Quarta-feira, dentro do horário comercial das duas marcas, e sábado, fora dele.
    let(:business) { Time.utc(2026, 11, 18, 15) }
    let(:off_hours) { Time.utc(2026, 11, 21, 15) }

    def route(brand, received_at:, **facts)
      Tenancy.with_brand(brand) do
        queues = Routing::Queue.includes(:team).to_h { |queue| [ queue.name, queue.team&.business_hours ] }
        matcher = Routing::Matcher.new(Routing::CompiledRules.compile, business_hours_for: queues.method(:[]))
        rule = matcher.first_match({ brand: brand.slug, received_at: received_at }.merge(facts))
        [ rule["name"], rule["then"]["queue"], rule["then"]["priority"] ]
      end
    end

    it "levam cada combinação de fatos da InfinitePay à regra esperada" do
      cases = {
        { priority: "high", segment: "alto_tpv", category: "repasse" } =>
          [ "InfinitePay · Urgente · Alto volume", "ip-urgente", 100 ],
        { priority: "high", segment: "baixo_tpv", category: nil } => [ "InfinitePay · Urgente", "ip-urgente", 95 ],
        { priority: "normal", segment: "alto_tpv", category: "repasse" } =>
          [ "InfinitePay · Repasse · Alto volume", "ip-financeiro-prioritaria", 90 ],
        { priority: "normal", segment: "alto_tpv", category: "transacao" } =>
          [ "InfinitePay · Transação · Alto volume", "ip-transacoes", 80 ],
        { priority: "normal", segment: "baixo_tpv", category: "maquininha" } =>
          [ "InfinitePay · Maquininha", "ip-maquininha", 65 ],
        { priority: "normal", segment: nil, category: "transacao" } => [ "InfinitePay · Transação", "ip-transacoes", 60 ],
        { priority: "normal", segment: "medio_tpv", category: "maquininha", received_at: off_hours } =>
          [ "InfinitePay · Maquininha · Fora do horário", "ip-maquininha", 55 ],
        { priority: "normal", segment: "medio_tpv", category: "repasse" } => [ "InfinitePay · Repasse", "ip-financeiro", 50 ],
        { priority: "normal", segment: "baixo_tpv", category: "taxas", channel: "whatsapp" } =>
          [ "InfinitePay · Taxas", "ip-suporte-geral", 35 ],
        { priority: "normal", segment: "baixo_tpv", category: "app", channel: "chat" } =>
          [ "InfinitePay · App", "ip-suporte-geral", 25 ],
        { priority: "normal", segment: "alto_tpv", category: "taxas", channel: "email" } =>
          [ "InfinitePay · Taxas · E-mail", "ip-suporte-geral", 20 ],
        { priority: "normal", segment: "medio_tpv", category: nil } =>
          [ "InfinitePay · Geral · Médio e alto volume", "ip-suporte-geral", 15 ],
        { priority: "normal", segment: "baixo_tpv", category: nil } => [ "InfinitePay · Geral", "ip-suporte-geral", 10 ]
      }

      cases.each do |facts, expected|
        expect(route(infinitepay, **{ received_at: business }.merge(facts))).to eq(expected), facts.inspect
      end
    end

    it "levam cada combinação de fatos da JIM à regra esperada" do
      cases = {
        { priority: "high", segment: "high_tpv", category: "app" } => [ "JIM · Urgent · High volume", "jim-urgent", 100 ],
        { priority: "high", segment: nil, category: "fees" } => [ "JIM · Urgent", "jim-urgent", 95 ],
        { priority: "normal", segment: "high_tpv", category: "payout" } =>
          [ "JIM · Payout · High volume", "jim-finance-priority", 90 ],
        { priority: "normal", segment: "high_tpv", category: "transaction" } =>
          [ "JIM · Transaction · High volume", "jim-transactions", 80 ],
        { priority: "normal", segment: "low_tpv", category: "card_reader" } => [ "JIM · Card reader", "jim-card-reader", 65 ],
        { priority: "normal", segment: "mid_tpv", category: "transaction" } => [ "JIM · Transaction", "jim-transactions", 60 ],
        { priority: "normal", segment: "low_tpv", category: "card_reader", received_at: off_hours } =>
          [ "JIM · Card reader · Off hours", "jim-card-reader", 55 ],
        { priority: "normal", segment: "low_tpv", category: "payout" } => [ "JIM · Payout", "jim-finance", 50 ],
        { priority: "normal", segment: "low_tpv", category: "fees", channel: "chat" } =>
          [ "JIM · Fees", "jim-general-support", 35 ],
        { priority: "normal", segment: "mid_tpv", category: "app", channel: "email" } =>
          [ "JIM · App", "jim-general-support", 25 ],
        { priority: "normal", segment: "low_tpv", category: "fees", channel: "email" } =>
          [ "JIM · Fees · Email", "jim-general-support", 20 ],
        { priority: "normal", segment: "high_tpv", category: nil } =>
          [ "JIM · General · Mid and high volume", "jim-general-support", 15 ],
        { priority: "normal", segment: nil, category: nil } => [ "JIM · General", "jim-general-support", 10 ]
      }

      cases.each do |facts, expected|
        expect(route(jim, **{ received_at: business }.merge(facts))).to eq(expected), facts.inspect
      end
    end
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

# Seeds do Cloudesk: marcas, canais das marcas, equipes, filas, regras, atendentes e lojistas sintéticos.
# Nenhum dado real. Rodam com o papel dono, que grava em brands, e definem a marca por transação
# com Tenancy.with_brand, o mesmo caminho da aplicação.
#
# Determinismo: o Faker usa uma semente fixa, e os valores são gerados sempre na mesma ordem.
# Cada registro é buscado por uma chave natural e criado só se não existe; por isso rodar as seeds
# de novo no mesmo banco não duplica registros.
require "faker"

seed = 20_261_115
contacts_per_brand = 50
human_attendants_per_brand = 4

weekdays = { "weekdays" => [ 1, 2, 3, 4, 5 ], "from" => "08:00", "to" => "20:00" }

catalog = [
  {
    slug: "infinitepay",
    name: "InfinitePay",
    locale: "pt-BR",
    ai_attendant: "Agente IA InfinitePay",
    segments: { "alto_tpv" => 2, "medio_tpv" => 3, "baixo_tpv" => 5 },
    phone: { country: "+55", areas: %w[11 21 31 41 51 61 71 81], prefix: "9", digits: 8 },
    whatsapp_numbers: [
      { phone_number_id: "110000000000001", display: "551140000001" },
      { phone_number_id: "110000000000002", display: "551140000002" }
    ],
    support_emails: %w[suporte@infinitepay.test financeiro@infinitepay.test],
    teams: [
      { name: "Financeiro", skills: %w[repasse taxas transacao],
        business_hours: weekdays.merge("timezone" => "America/Sao_Paulo") },
      { name: "Suporte Técnico", skills: %w[maquininha app],
        business_hours: weekdays.merge("timezone" => "America/Sao_Paulo") }
    ],
    queues: [
      { name: "ip-financeiro", team: "Financeiro", sla_minutes: 60, capacity: 50, first_attendant: "human" },
      { name: "ip-financeiro-prioritaria", team: "Financeiro", sla_minutes: 15, capacity: 20,
        first_attendant: "ai", overflow: "ip-financeiro", escalation: "ip-financeiro" },
      { name: "ip-urgente", team: "Financeiro", sla_minutes: 10, capacity: 15, first_attendant: "human" },
      { name: "ip-transacoes", team: "Financeiro", sla_minutes: 30, capacity: 60, first_attendant: "ai",
        escalation: "ip-financeiro" },
      { name: "ip-maquininha", team: "Suporte Técnico", sla_minutes: 45, capacity: 60, first_attendant: "ai" },
      { name: "ip-suporte-geral", team: "Suporte Técnico", sla_minutes: 120, capacity: 100, first_attendant: "ai" }
    ],
    rules: [
      { name: "InfinitePay · Urgente · Alto volume", position: 1,
        when: { brand: "infinitepay", priority: "high", segment: "alto_tpv" },
        then: { queue: "ip-urgente", priority: 100, sla_minutes: 10, first_attendant: "human" } },
      { name: "InfinitePay · Urgente", position: 2,
        when: { brand: "infinitepay", priority: "high" },
        then: { queue: "ip-urgente", priority: 95, sla_minutes: 15, first_attendant: "human" } },
      { name: "InfinitePay · Repasse · Alto volume", position: 3,
        when: { brand: "infinitepay", category: "repasse", segment: "alto_tpv" },
        then: { queue: "ip-financeiro-prioritaria", priority: 90, sla_minutes: 15, first_attendant: "ai" } },
      { name: "InfinitePay · Transação · Alto volume", position: 4,
        when: { brand: "infinitepay", category: "transacao", segment: "alto_tpv" },
        then: { queue: "ip-transacoes", priority: 80, sla_minutes: 20, first_attendant: "ai" } },
      { name: "InfinitePay · Maquininha", position: 5,
        when: { brand: "infinitepay", category: "maquininha", hours: "business" },
        then: { queue: "ip-maquininha", priority: 65, sla_minutes: 45, first_attendant: "ai" } },
      { name: "InfinitePay · Transação", position: 6,
        when: { brand: "infinitepay", category: "transacao" },
        then: { queue: "ip-transacoes", priority: 60, sla_minutes: 45, first_attendant: "ai" } },
      { name: "InfinitePay · Maquininha · Fora do horário", position: 7,
        when: { brand: "infinitepay", category: "maquininha", hours: "off_hours" },
        then: { queue: "ip-maquininha", priority: 55, sla_minutes: 90, first_attendant: "ai" } },
      { name: "InfinitePay · Repasse", position: 8,
        when: { brand: "infinitepay", category: "repasse" },
        then: { queue: "ip-financeiro", priority: 50, sla_minutes: 60, first_attendant: "human" } },
      { name: "InfinitePay · Taxas", position: 9,
        when: { brand: "infinitepay", category: "taxas", channel: %w[chat whatsapp] },
        then: { queue: "ip-suporte-geral", priority: 35, sla_minutes: 90, first_attendant: "ai" } },
      { name: "InfinitePay · App", position: 10,
        when: { brand: "infinitepay", category: "app" },
        then: { queue: "ip-suporte-geral", priority: 25, sla_minutes: 60, first_attendant: "ai" } },
      { name: "InfinitePay · Taxas · E-mail", position: 11,
        when: { brand: "infinitepay", category: "taxas", channel: "email" },
        then: { queue: "ip-suporte-geral", priority: 20, sla_minutes: 240, first_attendant: "ai" } },
      { name: "InfinitePay · Geral · Médio e alto volume", position: 12,
        when: { brand: "infinitepay", segment: %w[medio_tpv alto_tpv] },
        then: { queue: "ip-suporte-geral", priority: 15, sla_minutes: 120, first_attendant: "ai" } },
      { name: "InfinitePay · Geral", position: 13,
        when: { brand: "infinitepay" },
        then: { queue: "ip-suporte-geral", priority: 10, sla_minutes: 120, first_attendant: "ai" } }
    ]
  },
  {
    slug: "jim",
    name: "JIM",
    locale: "en-US",
    ai_attendant: "JIM AI Agent",
    segments: { "high_tpv" => 2, "mid_tpv" => 3, "low_tpv" => 5 },
    phone: { country: "+1", areas: %w[212 305 415 512 617], prefix: "", digits: 7 },
    whatsapp_numbers: [
      { phone_number_id: "120000000000001", display: "15555550101" },
      { phone_number_id: "120000000000002", display: "15555550102" }
    ],
    support_emails: %w[support@jim.test payouts@jim.test],
    teams: [
      { name: "Finance", skills: %w[payout fees transaction],
        business_hours: weekdays.merge("timezone" => "America/New_York") },
      { name: "Technical Support", skills: %w[card_reader app],
        business_hours: weekdays.merge("timezone" => "America/New_York") }
    ],
    queues: [
      { name: "jim-finance", team: "Finance", sla_minutes: 60, capacity: 50, first_attendant: "human" },
      { name: "jim-finance-priority", team: "Finance", sla_minutes: 15, capacity: 20,
        first_attendant: "ai", overflow: "jim-finance", escalation: "jim-finance" },
      { name: "jim-urgent", team: "Finance", sla_minutes: 10, capacity: 15, first_attendant: "human" },
      { name: "jim-transactions", team: "Finance", sla_minutes: 30, capacity: 60, first_attendant: "ai",
        escalation: "jim-finance" },
      { name: "jim-card-reader", team: "Technical Support", sla_minutes: 45, capacity: 60, first_attendant: "ai" },
      { name: "jim-general-support", team: "Technical Support", sla_minutes: 120, capacity: 100,
        first_attendant: "ai" }
    ],
    rules: [
      { name: "JIM · Urgent · High volume", position: 1,
        when: { brand: "jim", priority: "high", segment: "high_tpv" },
        then: { queue: "jim-urgent", priority: 100, sla_minutes: 10, first_attendant: "human" } },
      { name: "JIM · Urgent", position: 2,
        when: { brand: "jim", priority: "high" },
        then: { queue: "jim-urgent", priority: 95, sla_minutes: 15, first_attendant: "human" } },
      { name: "JIM · Payout · High volume", position: 3,
        when: { brand: "jim", category: "payout", segment: "high_tpv" },
        then: { queue: "jim-finance-priority", priority: 90, sla_minutes: 15, first_attendant: "ai" } },
      { name: "JIM · Transaction · High volume", position: 4,
        when: { brand: "jim", category: "transaction", segment: "high_tpv" },
        then: { queue: "jim-transactions", priority: 80, sla_minutes: 20, first_attendant: "ai" } },
      { name: "JIM · Card reader", position: 5,
        when: { brand: "jim", category: "card_reader", hours: "business" },
        then: { queue: "jim-card-reader", priority: 65, sla_minutes: 45, first_attendant: "ai" } },
      { name: "JIM · Transaction", position: 6,
        when: { brand: "jim", category: "transaction" },
        then: { queue: "jim-transactions", priority: 60, sla_minutes: 45, first_attendant: "ai" } },
      { name: "JIM · Card reader · Off hours", position: 7,
        when: { brand: "jim", category: "card_reader", hours: "off_hours" },
        then: { queue: "jim-card-reader", priority: 55, sla_minutes: 90, first_attendant: "ai" } },
      { name: "JIM · Payout", position: 8,
        when: { brand: "jim", category: "payout" },
        then: { queue: "jim-finance", priority: 50, sla_minutes: 60, first_attendant: "human" } },
      { name: "JIM · Fees", position: 9,
        when: { brand: "jim", category: "fees", channel: %w[chat whatsapp] },
        then: { queue: "jim-general-support", priority: 35, sla_minutes: 90, first_attendant: "ai" } },
      { name: "JIM · App", position: 10,
        when: { brand: "jim", category: "app" },
        then: { queue: "jim-general-support", priority: 25, sla_minutes: 60, first_attendant: "ai" } },
      { name: "JIM · Fees · Email", position: 11,
        when: { brand: "jim", category: "fees", channel: "email" },
        then: { queue: "jim-general-support", priority: 20, sla_minutes: 240, first_attendant: "ai" } },
      { name: "JIM · General · Mid and high volume", position: 12,
        when: { brand: "jim", segment: %w[mid_tpv high_tpv] },
        then: { queue: "jim-general-support", priority: 15, sla_minutes: 120, first_attendant: "ai" } },
      { name: "JIM · General", position: 13,
        when: { brand: "jim" },
        then: { queue: "jim-general-support", priority: 10, sla_minutes: 120, first_attendant: "ai" } }
    ]
  }
]

Faker::Config.random = Random.new(seed)
Faker::UniqueGenerator.clear

begin
  catalog.each do |entry|
    Faker::Config.locale = entry[:locale]
    # Segmento sorteado com peso: cada segmento entra no sorteio tantas vezes quanto o peso.
    segment_pool = entry[:segments].flat_map { |segment, weight| [ segment ] * weight }

    brand = Brand.find_or_create_by!(slug: entry[:slug]) do |record|
      record.name = entry[:name]
      record.locale = entry[:locale]
    end

    # Números de WhatsApp e e-mails de suporte da marca. brand_channels fica fora do RLS e é
    # buscada pelo par (channel, value), único entre as marcas.
    entry[:whatsapp_numbers].each do |number|
      BrandChannel.find_or_create_by!(channel: "whatsapp", value: number[:phone_number_id]) do |record|
        record.brand = brand
        record.display_value = number[:display]
      end
    end

    entry[:support_emails].each do |email|
      BrandChannel.find_or_create_by!(channel: "email", value: email) do |record|
        record.brand = brand
        record.display_value = email
      end
    end

    Tenancy.with_brand(brand) do
      teams = entry[:teams].to_h do |attributes|
        team = Team.find_or_create_by!(name: attributes[:name]) do |record|
          record.skills = attributes[:skills]
          record.business_hours = attributes[:business_hours]
        end
        [ attributes[:name], team ]
      end

      # A fila de transbordo vem antes, no catálogo, da fila que aponta para ela.
      queues = {}
      entry[:queues].each do |attributes|
        queues[attributes[:name]] = Routing::Queue.find_or_create_by!(name: attributes[:name]) do |record|
          record.team = teams.fetch(attributes[:team])
          record.sla_minutes = attributes[:sla_minutes]
          record.capacity = attributes[:capacity]
          record.first_attendant = attributes[:first_attendant]
          record.overflow_queue = queues.fetch(attributes[:overflow]) if attributes[:overflow]
        end
      end

      # Fila de escalação: gravada só quando a fila ainda não tem uma.
      entry[:queues].each do |attributes|
        next unless attributes[:escalation]

        queue = queues.fetch(attributes[:name])
        queue.update!(escalation_queue: queues.fetch(attributes[:escalation])) if queue.escalation_queue_id.nil?
      end

      entry[:rules].each do |attributes|
        RoutingRule.find_or_create_by!(name: attributes[:name], version: 1) do |record|
          record.position = attributes[:position]
          record.when = attributes[:when]
          record.then = attributes[:then]
          record.active = true
        end
      end

      Attendant.find_or_create_by!(kind: "ai", name: entry[:ai_attendant]) do |record|
        record.capacity = 1000
      end

      human_attendants_per_brand.times do |index|
        name = Faker::Name.unique.name
        team = teams.values[index % teams.size]

        Attendant.find_or_create_by!(kind: "human", name: name) do |record|
          record.team = team
          record.capacity = 5
          record.skills = team.skills
        end
      end

      contacts_per_brand.times do
        phone_format = entry[:phone]
        name = Faker::Name.name
        phone = [
          phone_format[:country],
          Faker::Base.sample(phone_format[:areas]),
          phone_format[:prefix],
          Faker::Number.unique.number(digits: phone_format[:digits])
        ].join
        # O username do Faker pt-BR traz acentos do nome; o e-mail fica em ASCII, como os e-mails
        # reais de lojistas. A transliteração não consome a semente: nomes e telefones não mudam.
        username = Faker::Internet.unique.username(specifier: name, separators: [ "." ])
        email = "#{I18n.transliterate(username)}@example.com"
        app_id = "app-#{Faker::Alphanumeric.unique.alphanumeric(number: 12)}"
        segment = Faker::Base.sample(segment_pool)

        # O lojista é buscado pela identidade de canal.
        next if ContactIdentity.exists?(channel: "whatsapp", value: phone)

        contact = Contact.create!(name: name, segment: segment, locale: entry[:locale])
        contact.identities.create!(channel: "whatsapp", value: phone)
        contact.identities.create!(channel: "email", value: email)
        contact.identities.create!(channel: "chat", value: app_id)
      end
    end
  end
ensure
  Faker::Config.locale = nil
end

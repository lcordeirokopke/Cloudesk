# Seeds do Cloudesk: marcas, equipes, filas, regras, atendentes e lojistas sintéticos.
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
    segments: %w[alto_tpv medio_tpv baixo_tpv],
    phone: { country: "+55", areas: %w[11 21 31 41 51 61 71 81], prefix: "9", digits: 8 },
    teams: [
      { name: "Financeiro", skills: %w[repasse taxas transacao],
        business_hours: weekdays.merge("timezone" => "America/Sao_Paulo") },
      { name: "Suporte Técnico", skills: %w[maquininha app],
        business_hours: weekdays.merge("timezone" => "America/Sao_Paulo") }
    ],
    queues: [
      { name: "ip-financeiro", team: "Financeiro", sla_minutes: 60, capacity: 50, first_attendant: "human" },
      { name: "ip-financeiro-prioritaria", team: "Financeiro", sla_minutes: 15, capacity: 20,
        first_attendant: "ai", overflow: "ip-financeiro" },
      { name: "ip-suporte-geral", team: "Suporte Técnico", sla_minutes: 120, capacity: 100, first_attendant: "ai" }
    ],
    rules: [
      { name: "InfinitePay · Repasse · Alto volume", position: 1,
        when: { brand: "infinitepay", category: "repasse", segment: "alto_tpv" },
        then: { queue: "ip-financeiro-prioritaria", priority: 90, sla_minutes: 15, first_attendant: "ai" } },
      { name: "InfinitePay · Repasse", position: 2,
        when: { brand: "infinitepay", category: "repasse" },
        then: { queue: "ip-financeiro", priority: 50, sla_minutes: 60, first_attendant: "human" } },
      { name: "InfinitePay · Geral", position: 3,
        when: { brand: "infinitepay" },
        then: { queue: "ip-suporte-geral", priority: 10, sla_minutes: 120, first_attendant: "ai" } }
    ]
  },
  {
    slug: "jim",
    name: "JIM",
    locale: "en-US",
    ai_attendant: "JIM AI Agent",
    segments: %w[high_tpv mid_tpv low_tpv],
    phone: { country: "+1", areas: %w[212 305 415 512 617], prefix: "", digits: 7 },
    teams: [
      { name: "Finance", skills: %w[payout fees transaction],
        business_hours: weekdays.merge("timezone" => "America/New_York") },
      { name: "Technical Support", skills: %w[card_reader app],
        business_hours: weekdays.merge("timezone" => "America/New_York") }
    ],
    queues: [
      { name: "jim-finance", team: "Finance", sla_minutes: 60, capacity: 50, first_attendant: "human" },
      { name: "jim-finance-priority", team: "Finance", sla_minutes: 15, capacity: 20,
        first_attendant: "ai", overflow: "jim-finance" },
      { name: "jim-general-support", team: "Technical Support", sla_minutes: 120, capacity: 100,
        first_attendant: "ai" }
    ],
    rules: [
      { name: "JIM · Payout · High volume", position: 1,
        when: { brand: "jim", category: "payout", segment: "high_tpv" },
        then: { queue: "jim-finance-priority", priority: 90, sla_minutes: 15, first_attendant: "ai" } },
      { name: "JIM · Payout", position: 2,
        when: { brand: "jim", category: "payout" },
        then: { queue: "jim-finance", priority: 50, sla_minutes: 60, first_attendant: "human" } },
      { name: "JIM · General", position: 3,
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

    brand = Brand.find_or_create_by!(slug: entry[:slug]) do |record|
      record.name = entry[:name]
      record.locale = entry[:locale]
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

      entry[:rules].each do |attributes|
        RoutingRule.find_or_create_by!(name: attributes[:name], version: 1) do |record|
          record.position = attributes[:position]
          record.when = attributes[:when]
          record.then = attributes[:then]
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
        email = "#{Faker::Internet.unique.username(specifier: name, separators: [ '.' ])}@example.com"
        app_id = "app-#{Faker::Alphanumeric.unique.alphanumeric(number: 12)}"
        segment = Faker::Base.sample(entry[:segments])

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

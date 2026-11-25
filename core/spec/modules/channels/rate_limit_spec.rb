require "rails_helper"

RSpec.describe Channels::RateLimit do
  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:now) { Time.zone.parse("2026-11-23 14:00:00.250") }
  let(:brand) { infinitepay.tap { |record| record.inbound_rate_limit_per_second = 3 } }
  let(:other) { jim.tap { |record| record.inbound_rate_limit_per_second = 3 } }

  before { allow(Rails).to receive(:cache).and_return(store) }

  def check(counts, at: now)
    described_class.check(counts, channel: "chat", now: at)
  end

  it "deixa passar dentro do limite" do
    expect(check({ brand => 1 }).allowed).to be(true)
    expect(check({ brand => 1 }).allowed).to be(true)
  end

  it "deixa passar no limite exato e recusa acima dele, com marca, contagem e limite" do
    3.times { expect(check({ brand => 1 }).allowed).to be(true) }

    result = check({ brand => 1 })

    expect(result).to have_attributes(allowed: false, brand: brand, count: 4, limit: 3)
  end

  it "abre uma janela nova no segundo seguinte" do
    3.times { check({ brand => 1 }) }
    expect(check({ brand => 1 }).allowed).to be(false)

    expect(check({ brand => 1 }, at: now + 1.second).allowed).to be(true)
  end

  it "conta cada mensagem da requisição" do
    expect(check({ brand => 3 }).allowed).to be(true)
    expect(check({ brand => 1 }).allowed).to be(false)

    expect(check({ brand => 4 }, at: now + 1.second)).to have_attributes(allowed: false, count: 4)
  end

  it "conta as marcas de forma independente" do
    3.times { check({ brand => 1 }) }

    expect(check({ other => 3 }).allowed).to be(true)
    expect(check({ brand => 1 }).allowed).to be(false)
  end

  it "recusa quando alguma marca passa do limite, e o incremento das marcas já contadas fica" do
    result = check({ other => 2, brand => 4 })

    expect(result).to have_attributes(allowed: false, brand: brand)
    expect(store.read(described_class.key(other, now.to_i)).to_i).to eq(2)
  end

  it "grava a recusa no log com marca, canal, contagem e limite" do
    3.times { check({ brand => 1 }) }
    allow(Rails.logger).to receive(:warn)

    check({ brand => 1 })

    expect(Rails.logger).to have_received(:warn).with(include("infinitepay", "chat", "4 mensagens", "limite 3"))
  end

  it "deixa passar com o contador indisponível e registra em log" do
    allow(store).to receive(:increment).and_return(nil)
    allow(Rails.logger).to receive(:warn)

    5.times { expect(check({ brand => 1 }).allowed).to be(true) }

    expect(Rails.logger).to have_received(:warn).with(include("sem contador", "infinitepay")).exactly(5).times
  end

  describe ".check_widget" do
    let(:now) { Time.zone.parse("2026-11-23 14:00:00") }
    let(:contact) { seed_contact(brand, 0) }
    let(:second_contact) { seed_contact(brand, 1) }
    let(:third_contact) { seed_contact(brand, 2) }

    def check_widget(contact, brand: self.brand, at: now)
      described_class.check_widget(brand, contact, now: at)
    end

    it "deixa passar 5 mensagens do lojista e recusa a sexta, com escopo, contagem, limite e o tempo até a janela seguinte" do
      5.times { expect(check_widget(contact).allowed).to be(true) }

      expect(check_widget(contact)).to have_attributes(allowed: false, scope: :contact, count: 6, limit: 5, retry_after: 10)
    end

    it "conta as mensagens do lojista na mesma janela de 10 s e informa o tempo restante dela" do
      5.times { check_widget(contact) }

      expect(check_widget(contact, at: now + 7.seconds)).to have_attributes(allowed: false, scope: :contact, retry_after: 3)
    end

    it "abre uma janela nova do lojista 10 segundos depois" do
      6.times { check_widget(contact) }

      expect(check_widget(contact, at: now + 10.seconds).allowed).to be(true)
    end

    it "conta os lojistas de forma independente" do
      6.times { check_widget(contact) }

      expect(check_widget(second_contact).allowed).to be(true)
    end

    it "não incrementa o contador do widget da marca na recusa por lojista" do
      8.times { check_widget(contact) }

      expect(store.read(described_class.widget_brand_key(brand, now.to_i)).to_i).to eq(5)
    end

    it "recusa a décima primeira mensagem do segundo na marca, de 3 lojistas" do
      5.times { check_widget(contact) }
      5.times { expect(check_widget(second_contact).allowed).to be(true) }

      expect(check_widget(third_contact)).to have_attributes(allowed: false, scope: :brand, count: 11, limit: 10, retry_after: 1)
      expect(check_widget(third_contact, at: now + 1.second).allowed).to be(true)
    end

    it "conta as marcas de forma independente" do
      5.times { check_widget(contact) }
      5.times { check_widget(second_contact) }
      expect(check_widget(third_contact).allowed).to be(false)

      expect(check_widget(seed_contact(other), brand: other).allowed).to be(true)
    end

    it "não toca no contador da marca, nos envios e nas recusas" do
      6.times { check_widget(contact) }
      5.times { check_widget(second_contact) }
      expect(check_widget(third_contact).allowed).to be(false)

      expect(store.read(described_class.key(brand, now.to_i))).to be_nil
    end

    it "deixa passar com o contador da marca acima do limite" do
      4.times { check({ brand => 1 }) }
      expect(check({ brand => 1 }).allowed).to be(false)

      expect(check_widget(contact).allowed).to be(true)
    end

    it "deixa passar com o contador indisponível e registra os dois avisos em log" do
      allow(store).to receive(:increment).and_return(nil)
      allow(Rails.logger).to receive(:warn)

      expect(check_widget(contact).allowed).to be(true)

      expect(Rails.logger).to have_received(:warn)
        .with(include("sem contador", "infinitepay", contact.id, "limite do lojista não conferido")).once
      expect(Rails.logger).to have_received(:warn)
        .with(include("sem contador", "infinitepay", contact.id, "teto do widget não conferido")).once
    end

    it "grava a recusa por lojista no log com marca e id, sem nome nem identidade" do
      5.times { check_widget(contact) }
      messages = []
      allow(Rails.logger).to receive(:warn) { |message| messages << message }

      check_widget(contact)

      expect(messages).to contain_exactly(include("infinitepay", contact.id, "6 mensagens em 10 s", "limite 5"))
      expect(messages.first).not_to include(contact.name)
      expect(messages.first).not_to include(identity_of(contact, "chat"))
    end

    it "grava a recusa pelo teto do widget no log com marca e id do lojista" do
      5.times { check_widget(contact) }
      5.times { check_widget(second_contact) }
      allow(Rails.logger).to receive(:warn)

      check_widget(third_contact)

      expect(Rails.logger).to have_received(:warn)
        .with(include("infinitepay", third_contact.id, "11 mensagens no segundo na marca", "limite 10"))
    end
  end
end

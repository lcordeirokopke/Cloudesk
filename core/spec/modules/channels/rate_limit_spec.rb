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
end

require "rails_helper"

RSpec.describe Routing::BusinessHours do
  let(:config) do
    { "weekdays" => [ 1, 2, 3, 4, 5 ], "from" => "08:00", "to" => "20:00", "timezone" => "America/Sao_Paulo" }
  end

  subject(:hours) { described_class.new(config) }

  # 2026-11-16 é segunda-feira. São Paulo fica em UTC-3.
  it "dentro do horário, em dia útil" do
    expect(hours.open_at?(Time.utc(2026, 11, 16, 13, 0))).to be(true)
  end

  it "fora do horário, em dia útil" do
    expect(hours.open_at?(Time.utc(2026, 11, 16, 23, 30))).to be(false)
  end

  it "o início está dentro e o fim está fora" do
    expect(hours.open_at?(Time.utc(2026, 11, 16, 11, 0))).to be(true)
    expect(hours.open_at?(Time.utc(2026, 11, 16, 10, 59))).to be(false)
    expect(hours.open_at?(Time.utc(2026, 11, 16, 23, 0))).to be(false)
  end

  it "confere no fuso da equipe" do
    # 02:00 UTC de terça é 23:00 de segunda em São Paulo.
    expect(hours.open_at?(Time.utc(2026, 11, 17, 2, 0))).to be(false)
    # 10:30 UTC é 07:30 em São Paulo e 05:30 em Nova York (UTC-5 em novembro); 12:30 UTC é 09:30
    # em São Paulo e 07:30 em Nova York; 13:30 UTC é 08:30 em Nova York.
    new_york = described_class.new(config.merge("timezone" => "America/New_York"))
    expect(hours.open_at?(Time.utc(2026, 11, 16, 10, 30))).to be(false)
    expect(hours.open_at?(Time.utc(2026, 11, 16, 12, 30))).to be(true)
    expect(new_york.open_at?(Time.utc(2026, 11, 16, 12, 30))).to be(false)
    expect(new_york.open_at?(Time.utc(2026, 11, 16, 13, 30))).to be(true)
  end

  it "fim de semana fica fora" do
    expect(hours.open_at?(Time.utc(2026, 11, 21, 15, 0))).to be(false)
    expect(hours.open_at?(Time.utc(2026, 11, 22, 15, 0))).to be(false)
  end

  it "horário incompleto ou inválido não tem instante comercial" do
    [ {}, config.except("timezone"), config.merge("timezone" => "Lua/Base"), config.merge("from" => "8h"),
      config.merge("weekdays" => [ 0 ]), config.merge("from" => "20:00", "to" => "08:00") ].each do |invalid|
      hours = described_class.new(invalid)
      expect(hours.valid?).to be(false), invalid.inspect
      expect(hours.open_at?(Time.utc(2026, 11, 16, 13, 0))).to be(false)
    end
  end
end

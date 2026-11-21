require "rails_helper"

RSpec.describe Routing::Dimensions do
  it "devolve as opções de cada dimensão da InfinitePay" do
    expect(described_class.for(infinitepay)).to eq(
      "channel" => %w[chat whatsapp email],
      "category" => %w[repasse taxas transacao maquininha app],
      "priority" => %w[high normal],
      "segment" => %w[alto_tpv medio_tpv baixo_tpv],
      "language" => %w[pt-BR],
      "hours" => %w[business off_hours]
    )
  end

  it "devolve as opções de cada dimensão da JIM" do
    expect(described_class.for(jim)).to include(
      "category" => %w[payout fees transaction card_reader app],
      "segment" => %w[high_tpv mid_tpv low_tpv],
      "language" => %w[en-US]
    )
  end

  it "usa as categorias do classificador" do
    [ infinitepay, jim ].each do |brand|
      expect(described_class.for(brand)["category"]).to eq(Routing::Classifier.categories(brand))
    end
  end

  it "marca ausente no YAML levanta KeyError" do
    expect { described_class.config_for("outra") }.to raise_error(KeyError, /outra/)
    expect { described_class.for(Brand.new(slug: "outra")) }.to raise_error(KeyError)
  end
end

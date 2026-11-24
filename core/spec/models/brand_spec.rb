require "rails_helper"

RSpec.describe Brand do
  it "tem limite de taxa de entrada de 500 mensagens por segundo nas marcas das seeds" do
    expect(Brand.order(:slug).pluck(:slug, :inbound_rate_limit_per_second)).to eq([ [ "infinitepay", 500 ], [ "jim", 500 ] ])
  end

  it "usa 500 como padrão da coluna" do
    expect(Brand.new.inbound_rate_limit_per_second).to eq(500)
  end

  it "exige limite de taxa inteiro maior que 0" do
    brand = infinitepay

    [ 0, -1, 1.5, nil ].each do |value|
      brand.inbound_rate_limit_per_second = value
      expect(brand).not_to be_valid, value.inspect
      expect(brand.errors[:inbound_rate_limit_per_second]).to be_present
    end

    brand.inbound_rate_limit_per_second = 1
    expect(brand).to be_valid
  end

  it "o banco recusa limite de taxa menor ou igual a 0" do
    expect_database_error(/brands_inbound_rate_limit_per_second_check/, OwnerRecord) do
      OwnerRecord.lease_connection.execute("UPDATE brands SET inbound_rate_limit_per_second = 0 WHERE slug = 'jim'")
    end
  end
end

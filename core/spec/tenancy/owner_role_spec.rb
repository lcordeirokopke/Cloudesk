require "rails_helper"

RSpec.describe "Papel dono" do
  let(:owner) { OwnerRecord.lease_connection }

  around do |example|
    OwnerRecord.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end

  def set_owner_brand(brand)
    owner.select_value("SELECT set_config('app.brand_id', #{owner.quote(brand.id)}, true)")
  end

  it "é dono das tabelas de domínio, sem superusuário e sem BYPASSRLS" do
    role = owner.select_one("SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
    owners = owner.select_values(<<~SQL)
      SELECT DISTINCT tableowner FROM pg_tables WHERE schemaname = 'public'
    SQL

    expect(role).to eq("rolname" => ENV.fetch("DB_OWNER_USERNAME"), "rolsuper" => false, "rolbypassrls" => false)
    expect(owners).to eq([ ENV.fetch("DB_OWNER_USERNAME") ])
  end

  it "sem marca definida, não vê nenhuma linha de domínio" do
    DatabaseHelpers::DOMAIN_MODELS.each do |model|
      expect(owner.select_value("SELECT count(*) FROM #{model.quoted_table_name}")).to eq(0)
    end
  end

  it "com a marca definida, vê só as linhas dela" do
    set_owner_brand(infinitepay)

    expect(owner.select_value("SELECT count(*) FROM contacts")).to eq(50)
    expect(owner.select_values("SELECT DISTINCT brand_id FROM contacts")).to eq([ infinitepay.id ])
  end

  it "não grava linha de outra marca" do
    set_owner_brand(infinitepay)

    expect_database_error(/row-level security/, OwnerRecord) do
      owner.execute(<<~SQL)
        INSERT INTO contacts (brand_id, name, locale, created_at, updated_at)
        VALUES (#{owner.quote(jim.id)}, 'Outra marca', 'en-US', now(), now())
      SQL
    end
  end
end

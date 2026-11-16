require "rails_helper"

RSpec.describe AuditEvent do
  def create_event
    described_class.create!(actor_type: "system", action: "conversation.opened", target_type: "Conversation")
  end

  it "gera o event_id como UUID v7 no banco" do
    Tenancy.with_brand(infinitepay) do
      event = create_event.reload

      expect(event.event_id).to match(/\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/)
      expect(event.id).to match(/\A\h{8}-\h{4}-7\h{3}-\h{4}-\h{12}\z/)
    end
  end

  it "recusa a alteração no model" do
    Tenancy.with_brand(infinitepay) do
      event = create_event

      expect { event.update!(reason: "alterado") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { event.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "com o papel da aplicação" do
    it "UPDATE, DELETE e TRUNCATE falham por falta de permissão" do
      Tenancy.with_brand(infinitepay) do
        event = create_event

        expect_database_error(/permission denied/) do
          described_class.where(id: event.id).update_all(reason: "alterado")
        end
        expect_database_error(/permission denied/) { described_class.where(id: event.id).delete_all }
        expect_database_error(/permission denied/) do
          ApplicationRecord.lease_connection.execute("TRUNCATE audit_events")
        end

        expect(described_class.find(event.id).reason).to be_nil
      end
    end

    it "não tem TRUNCATE em nenhuma tabela" do
      granted = ApplicationRecord.lease_connection.select_values(<<~SQL)
        SELECT table_name FROM information_schema.role_table_grants
         WHERE grantee = current_user AND privilege_type = 'TRUNCATE'
      SQL

      expect(granted).to be_empty
    end
  end

  describe "com o papel dono" do
    let(:owner) { OwnerRecord.lease_connection }

    around do |example|
      OwnerRecord.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end

    it "UPDATE, DELETE e TRUNCATE falham pelo trigger" do
      owner.select_value("SELECT set_config('app.brand_id', #{owner.quote(infinitepay.id)}, true)")
      event_id = owner.select_value(<<~SQL)
        INSERT INTO audit_events (brand_id, actor_type, action, target_type, created_at)
        VALUES (#{owner.quote(infinitepay.id)}, 'system', 'conversation.opened', 'Conversation', now())
        RETURNING id
      SQL

      expect_database_error(/audit_events is append-only/, OwnerRecord) do
        owner.execute("UPDATE audit_events SET reason = 'alterado' WHERE id = #{owner.quote(event_id)}")
      end
      expect_database_error(/audit_events is append-only/, OwnerRecord) do
        owner.execute("DELETE FROM audit_events WHERE id = #{owner.quote(event_id)}")
      end
      expect_database_error(/audit_events is append-only/, OwnerRecord) do
        owner.execute("TRUNCATE audit_events")
      end

      expect(owner.select_value("SELECT count(*) FROM audit_events WHERE id = #{owner.quote(event_id)}")).to eq(1)
    end
  end

  it "não usa ON DELETE CASCADE nas referências a outras tabelas" do
    actions = ApplicationRecord.lease_connection.select_values(<<~SQL)
      SELECT DISTINCT confdeltype FROM pg_constraint
       WHERE contype = 'f' AND conrelid = 'audit_events'::regclass
    SQL

    expect(actions).to eq([ "a" ])
  end
end

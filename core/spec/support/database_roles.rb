# Os testes conectam com o papel da aplicação. Este arquivo dá acesso ao papel dono, usado para
# rodar as seeds no banco de teste e para provar que o dono também obedece ao RLS.

# Conexão à parte com o papel dono, no mesmo banco de teste.
class OwnerRecord < ActiveRecord::Base
  self.abstract_class = true

  establish_connection(
    ActiveRecord::Base.connection_db_config.configuration_hash.merge(
      username: ENV.fetch("DB_OWNER_USERNAME"),
      password: ENV.fetch("DB_OWNER_PASSWORD")
    )
  )
end

module SeedRunner
  module_function

  # Roda bin/rails db:seed no banco do ambiente corrente, em outro processo, com o papel dono.
  def run
    env = {
      "RAILS_ENV" => Rails.env,
      "DB_USERNAME" => ENV.fetch("DB_OWNER_USERNAME"),
      "DB_PASSWORD" => ENV.fetch("DB_OWNER_PASSWORD")
    }
    system(env, "bin/rails", "db:seed", chdir: Rails.root.to_s, exception: true)
  end
end

module DatabaseHelpers
  DOMAIN_MODELS = [
    Team, Routing::Queue, RoutingRule, Contact, ContactIdentity, Attendant, Conversation,
    Message, Handoff, AuditEvent, CustomerMemory, ProcessedEvent
  ].freeze

  # Marcas criadas pelas seeds.
  def infinitepay
    Brand.find_by!(slug: "infinitepay")
  end

  def jim
    Brand.find_by!(slug: "jim")
  end

  # Roda o bloco em um savepoint: um erro do banco aborta só o savepoint, e o teste continua.
  def in_savepoint(record_class = ApplicationRecord, &block)
    record_class.transaction(requires_new: true, &block)
  end

  def expect_database_error(pattern, record_class = ApplicationRecord, &block)
    expect { in_savepoint(record_class, &block) }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  end

  # Apaga, com o papel dono, conversas gravadas com commit por exemplos fora da transação do RSpec,
  # com as mensagens e os audit_events delas. O trigger de audit_events fica desligado só durante
  # a limpeza, na mesma transação.
  def purge_conversations(brand, conversation_ids)
    return if conversation_ids.empty?

    connection = OwnerRecord.lease_connection
    ids = conversation_ids.map { |id| connection.quote(id) }.join(", ")
    OwnerRecord.transaction do
      connection.execute("SELECT set_config('app.brand_id', #{connection.quote(brand.id)}, true)")
      connection.execute("ALTER TABLE audit_events DISABLE TRIGGER audit_events_block_row_changes")
      connection.execute("DELETE FROM audit_events WHERE conversation_id IN (#{ids})")
      connection.execute("ALTER TABLE audit_events ENABLE TRIGGER audit_events_block_row_changes")
      connection.execute("DELETE FROM messages WHERE conversation_id IN (#{ids})")
      connection.execute("DELETE FROM conversations WHERE id IN (#{ids})")
    end
  end

  def current_setting(connection = ApplicationRecord.lease_connection)
    connection.select_value("SELECT current_setting('app.brand_id', true)")
  end
end

RSpec.configure do |config|
  config.include DatabaseHelpers

  # As marcas e os dados de base dos testes vêm das seeds.
  config.before(:suite) { SeedRunner.run }
end

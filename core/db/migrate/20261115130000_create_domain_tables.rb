# Tabelas de domínio do Cloudesk.
# Roda com o papel dono. Toda tabela, exceto brands, tem brand_id, Row-Level Security forçado,
# índice único em (brand_id, id) e chaves estrangeiras compostas com brand_id: a checagem de chave
# estrangeira ignora o RLS, e a chave composta impede a referência entre marcas.
# Nenhuma chave estrangeira usa ação ON DELETE.
class CreateDomainTables < ActiveRecord::Migration[8.1]
  CONVERSATION_STATES = %w[triage with_ai awaiting_human with_human resolved closed].freeze

  BRAND_SCOPED_TABLES = %w[
    teams
    queues
    routing_rules
    contacts
    contact_identities
    attendants
    conversations
    messages
    handoffs
    audit_events
    customer_memories
    processed_events
  ].freeze

  # Tabelas em que o papel da aplicação lê, insere, altera e exclui.
  READ_WRITE_TABLES = (BRAND_SCOPED_TABLES - %w[audit_events]).freeze

  CHANNEL_CHECK = "channel IN ('chat', 'whatsapp', 'email')".freeze
  ATTENDANT_KIND_VALUES = "('ai', 'human')".freeze

  # [tabela de origem, tabela de destino, coluna]
  BRAND_FOREIGN_KEYS = [
    %w[queues teams team_id],
    %w[queues queues overflow_queue_id],
    %w[contact_identities contacts contact_id],
    %w[attendants teams team_id],
    %w[conversations contacts contact_id],
    %w[conversations queues queue_id],
    %w[conversations attendants attendant_id],
    %w[messages conversations conversation_id],
    %w[messages attendants attendant_id],
    %w[handoffs conversations conversation_id],
    %w[audit_events conversations conversation_id],
    %w[audit_events routing_rules routing_rule_id],
    %w[customer_memories contacts contact_id]
  ].freeze

  def up
    create_enum :conversation_state, CONVERSATION_STATES

    create_brands
    create_teams
    create_queues
    create_routing_rules
    create_contacts
    create_contact_identities
    create_attendants
    create_conversations
    create_messages
    create_handoffs
    create_audit_events
    create_customer_memories
    create_processed_events

    add_foreign_keys
    enable_row_level_security
    block_audit_event_changes
    grant_app_role
  end

  def down
    (BRAND_SCOPED_TABLES.reverse + %w[brands]).each { |table| drop_table table }
    execute "DROP FUNCTION audit_events_append_only()"
    drop_enum :conversation_state
  end

  private

  def app_role
    quote_column_name(ENV.fetch("DB_APP_USERNAME"))
  end

  def create_brands
    create_table :brands, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :locale, null: false
      t.timestamps
      t.index :slug, unique: true
    end
  end

  # Tabela de domínio: id UUID v7, brand_id obrigatório e índice único (brand_id, id),
  # que serve de alvo às chaves estrangeiras compostas.
  def create_brand_table(name)
    create_table name, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :brand_id, null: false
      yield t
      t.index %i[brand_id id], unique: true
    end
  end

  def create_teams
    create_brand_table :teams do |t|
      t.string :name, null: false
      t.string :skills, array: true, null: false, default: []
      t.jsonb :business_hours, null: false, default: {}
      t.timestamps
      t.index %i[brand_id name], unique: true
    end
  end

  def create_queues
    create_brand_table :queues do |t|
      t.string :name, null: false
      t.uuid :team_id
      t.integer :sla_minutes, null: false
      t.integer :capacity, null: false
      t.string :first_attendant, null: false
      t.uuid :overflow_queue_id
      t.timestamps
      t.index %i[brand_id name], unique: true
      t.index %i[brand_id team_id]
      t.index %i[brand_id overflow_queue_id]
      t.check_constraint "first_attendant IN #{ATTENDANT_KIND_VALUES}", name: "queues_first_attendant_check"
    end
  end

  # Cada versão de uma regra é uma linha; rule_id é igual entre as versões da mesma regra.
  def create_routing_rules
    create_brand_table :routing_rules do |t|
      t.uuid :rule_id, null: false
      t.integer :version, null: false
      t.string :name, null: false
      t.integer :position, null: false
      t.jsonb :when, null: false, default: {}
      t.jsonb :then, null: false, default: {}
      t.datetime :created_at, null: false
      t.index %i[brand_id rule_id version], unique: true
    end
  end

  def create_contacts
    create_brand_table :contacts do |t|
      t.string :name, null: false
      t.string :segment
      t.string :locale, null: false
      t.timestamps
    end
  end

  def create_contact_identities
    create_brand_table :contact_identities do |t|
      t.uuid :contact_id, null: false
      t.string :channel, null: false
      t.string :value, null: false
      t.timestamps
      t.index %i[brand_id channel value], unique: true
      t.index %i[brand_id contact_id]
      t.check_constraint CHANNEL_CHECK, name: "contact_identities_channel_check"
    end
  end

  def create_attendants
    create_brand_table :attendants do |t|
      t.string :kind, null: false
      t.string :name, null: false
      t.uuid :team_id
      t.integer :capacity, null: false
      t.string :skills, array: true, null: false, default: []
      t.timestamps
      t.index %i[brand_id team_id]
      t.check_constraint "kind IN #{ATTENDANT_KIND_VALUES}", name: "attendants_kind_check"
    end
  end

  def create_conversations
    create_brand_table :conversations do |t|
      t.uuid :contact_id, null: false
      t.string :channel, null: false
      t.enum :state, enum_type: :conversation_state, null: false, default: "triage"
      t.uuid :queue_id
      t.uuid :attendant_id
      t.integer :priority, null: false, default: 0
      t.string :category
      t.integer :last_sequence, null: false, default: 0
      t.datetime :resolved_at
      t.timestamps
      t.index %i[brand_id contact_id]
      t.index %i[brand_id queue_id]
      t.index %i[brand_id attendant_id]
      t.check_constraint CHANNEL_CHECK, name: "conversations_channel_check"
    end
  end

  def create_messages
    create_brand_table :messages do |t|
      t.uuid :conversation_id, null: false
      t.integer :sequence, null: false
      t.string :channel, null: false
      t.string :author, null: false
      t.uuid :attendant_id
      t.text :body, null: false
      t.datetime :created_at, null: false
      t.index %i[brand_id conversation_id sequence], unique: true
      t.index %i[brand_id attendant_id]
      t.check_constraint CHANNEL_CHECK, name: "messages_channel_check"
      t.check_constraint "author IN ('customer', 'ai', 'analyst', 'system')", name: "messages_author_check"
    end
  end

  def create_handoffs
    create_brand_table :handoffs do |t|
      t.uuid :conversation_id, null: false
      t.string :reason, null: false
      t.text :summary, null: false
      t.jsonb :context, null: false, default: {}
      t.timestamps
      t.index %i[brand_id conversation_id]
    end
  end

  def create_audit_events
    create_brand_table :audit_events do |t|
      t.uuid :event_id, null: false, default: -> { "uuidv7()" }
      t.string :actor_type, null: false
      t.uuid :actor_id
      t.string :action, null: false
      t.string :target_type, null: false
      t.uuid :target_id
      t.uuid :conversation_id
      t.jsonb :before
      t.jsonb :after
      t.jsonb :payload, null: false, default: {}
      t.string :reason
      t.uuid :routing_rule_id
      t.integer :rule_version
      t.string :trace_id
      t.datetime :created_at, null: false
      t.index %i[brand_id event_id], unique: true
      t.index %i[brand_id conversation_id]
      t.index %i[brand_id routing_rule_id]
      t.index %i[brand_id trace_id]
    end
  end

  def create_customer_memories
    create_brand_table :customer_memories do |t|
      t.uuid :contact_id, null: false
      t.text :summary, null: false
      t.timestamps
      t.index %i[brand_id contact_id], unique: true
    end
  end

  def create_processed_events
    create_brand_table :processed_events do |t|
      t.string :idempotency_key, null: false
      t.jsonb :result, null: false, default: {}
      t.datetime :created_at, null: false
      t.index %i[brand_id idempotency_key], unique: true
    end
  end

  def add_foreign_keys
    BRAND_SCOPED_TABLES.each { |table| add_foreign_key table, :brands }

    BRAND_FOREIGN_KEYS.each do |from, to, column|
      add_foreign_key from, to, column: [ :brand_id, column ], primary_key: %i[brand_id id]
    end
  end

  # ENABLE e FORCE: o papel dono também obedece à política. Sem WITH CHECK, a expressão de USING
  # vale para leitura e escrita. Parâmetro ausente ou vazio vira NULL e não casa nenhuma linha.
  def enable_row_level_security
    BRAND_SCOPED_TABLES.each do |table|
      execute "ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{table} FORCE ROW LEVEL SECURITY"
      execute <<~SQL
        CREATE POLICY brand_isolation ON #{table}
          USING (brand_id = NULLIF(current_setting('app.brand_id', true), '')::uuid)
      SQL
    end
  end

  # Triggers de TRUNCATE só existem FOR EACH STATEMENT; por isso são dois triggers.
  def block_audit_event_changes
    execute <<~SQL
      CREATE FUNCTION audit_events_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'audit_events is append-only';
      END;
      $$
    SQL

    execute <<~SQL
      CREATE TRIGGER audit_events_block_row_changes
        BEFORE UPDATE OR DELETE ON audit_events
        FOR EACH ROW EXECUTE FUNCTION audit_events_append_only()
    SQL

    execute <<~SQL
      CREATE TRIGGER audit_events_block_truncate
        BEFORE TRUNCATE ON audit_events
        FOR EACH STATEMENT EXECUTE FUNCTION audit_events_append_only()
    SQL
  end

  # TRUNCATE não é concedido em nenhuma tabela.
  def grant_app_role
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON #{READ_WRITE_TABLES.join(', ')} TO #{app_role}"
    execute "GRANT SELECT, INSERT ON audit_events TO #{app_role}"
    execute "GRANT SELECT ON brands TO #{app_role}"
  end
end

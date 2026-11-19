# Tabelas e colunas dos canais de entrada. Roda com o papel dono, depois das migrações das gems
# Active Storage e Action Mailbox.
#
# brand_channels: números de WhatsApp e e-mails de suporte de cada marca. Fica fora do RLS, como
# brands: é lida para descobrir a marca da mensagem antes de a marca ser definida na transação.
# O papel da aplicação só lê.
#
# Active Storage e Action Mailbox: tabelas das gems, com chave primária bigint, sem brand_id e sem
# RLS. O e-mail chega antes de a marca ser conhecida, e a incineração do Action Mailbox apaga linhas.
# Nenhuma tabela de domínio aponta para elas.
class CreateChannelTables < ActiveRecord::Migration[8.1]
  GEM_TABLES = %w[
    active_storage_blobs
    active_storage_attachments
    active_storage_variant_records
    action_mailbox_inbound_emails
  ].freeze

  def up
    create_brand_channels
    add_reopen_window_to_brands
    add_channel_columns_to_messages
    add_conversation_indexes
    grant_app_role
  end

  def down
    revoke_app_role

    remove_index :conversations, name: "index_conversations_resolved"
    remove_index :conversations, name: "index_conversations_one_open_per_contact"

    remove_foreign_key :messages, :brand_channels, column: %i[brand_id brand_channel_id]
    remove_index :messages, name: "index_messages_on_external_id"
    remove_index :messages, %i[brand_id brand_channel_id]
    remove_column :messages, :brand_channel_id
    remove_column :messages, :attachments
    remove_column :messages, :external_id

    remove_check_constraint :brands, name: "brands_reopen_window_minutes_check"
    remove_column :brands, :reopen_window_minutes

    drop_table :brand_channels
  end

  private

  def app_role
    quote_column_name(ENV.fetch("DB_APP_USERNAME"))
  end

  def sequences_of(tables)
    tables.map { |table| select_value("SELECT pg_get_serial_sequence(#{quote(table)}, 'id')") }
  end

  # O par (channel, value) define a marca. value é o phone_number_id do WhatsApp ou o e-mail
  # normalizado; display_value é o número exibido no WhatsApp e, no e-mail, igual a value.
  def create_brand_channels
    create_table :brand_channels, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :brand_id, null: false
      t.string :channel, null: false
      t.string :value, null: false
      t.string :display_value
      t.timestamps
      t.index %i[channel value], unique: true
      t.index %i[brand_id id], unique: true
      t.check_constraint "channel IN ('whatsapp', 'email')", name: "brand_channels_channel_check"
    end

    add_foreign_key :brand_channels, :brands
  end

  # Prazo de reabertura da conversa resolvida, em minutos; padrão de 24 h.
  def add_reopen_window_to_brands
    add_column :brands, :reopen_window_minutes, :integer, null: false, default: 1440
    add_check_constraint :brands, "reopen_window_minutes > 0", name: "brands_reopen_window_minutes_check"
  end

  # external_id: id gerado por quem envia (wamid, Message-ID, id do cliente no chat); o mesmo id no
  # mesmo canal é reenvio técnico.
  # brand_channel_id: número ou e-mail da marca que recebeu a mensagem; vazio no chat.
  def add_channel_columns_to_messages
    add_column :messages, :external_id, :string
    add_column :messages, :attachments, :jsonb, null: false, default: []
    add_column :messages, :brand_channel_id, :uuid

    add_index :messages, %i[brand_id channel external_id], unique: true,
              where: "external_id IS NOT NULL", name: "index_messages_on_external_id"
    add_index :messages, %i[brand_id brand_channel_id]
    add_foreign_key :messages, :brand_channels, column: %i[brand_id brand_channel_id], primary_key: %i[brand_id id]
  end

  # Uma conversa não closed por lojista; resolved_at das conversas resolvidas, para a varredura do
  # prazo de reabertura.
  def add_conversation_indexes
    add_index :conversations, %i[brand_id contact_id], unique: true,
              where: "state <> 'closed'", name: "index_conversations_one_open_per_contact"
    add_index :conversations, %i[brand_id resolved_at],
              where: "state = 'resolved'", name: "index_conversations_resolved"
  end

  # TRUNCATE não é concedido em nenhuma tabela.
  def grant_app_role
    execute "GRANT SELECT ON brand_channels TO #{app_role}"
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON #{GEM_TABLES.join(', ')} TO #{app_role}"
    execute "GRANT USAGE, SELECT ON SEQUENCE #{sequences_of(GEM_TABLES).join(', ')} TO #{app_role}"
  end

  def revoke_app_role
    execute "REVOKE ALL ON brand_channels FROM #{app_role}"
    execute "REVOKE ALL ON SEQUENCE #{sequences_of(GEM_TABLES).join(', ')} FROM #{app_role}"
    execute "REVOKE ALL ON #{GEM_TABLES.join(', ')} FROM #{app_role}"
  end
end

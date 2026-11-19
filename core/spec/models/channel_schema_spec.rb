require "rails_helper"

RSpec.describe "Esquema dos canais" do
  let(:contact) { seed_contact(infinitepay) }

  def privileges(table)
    connection = ApplicationRecord.lease_connection
    role = connection.quote(ENV.fetch("DB_APP_USERNAME"))
    %w[SELECT INSERT UPDATE DELETE TRUNCATE].to_h do |privilege|
      [ privilege, connection.select_value("SELECT has_table_privilege(#{role}, #{connection.quote(table)}, '#{privilege}')") ]
    end
  end

  describe "brand_channels" do
    it "é visível sem marca definida, com dois números de WhatsApp e dois e-mails por marca" do
      expect(Tenancy.current_brand_id).to be_nil
      [ infinitepay, jim ].each do |brand|
        expect(BrandChannel.where(brand: brand).group(:channel).count).to eq("whatsapp" => 2, "email" => 2)
      end
      expect(BrandChannel.lookup("email", " Suporte@InfinitePay.test ").brand).to eq(infinitepay)
    end

    it "o papel da aplicação só lê" do
      expect(privileges("brand_channels")).to eq(
        "SELECT" => true, "INSERT" => false, "UPDATE" => false, "DELETE" => false, "TRUNCATE" => false
      )
      expect_database_error(/permission denied/) do
        BrandChannel.create!(brand: infinitepay, channel: "email", value: "novo@infinitepay.test")
      end
    end
  end

  it "o papel da aplicação lê, insere, altera e exclui nas tabelas do Active Storage e do Action Mailbox" do
    %w[active_storage_blobs active_storage_attachments active_storage_variant_records action_mailbox_inbound_emails].each do |table|
      expect(privileges(table)).to eq(
        "SELECT" => true, "INSERT" => true, "UPDATE" => true, "DELETE" => true, "TRUNCATE" => false
      ), table
    end
  end

  it "o prazo de reabertura padrão é de 24 h" do
    expect(infinitepay.reopen_window_minutes).to eq(1440)
    expect(jim.reopen_window).to eq(24.hours)
  end

  describe "conversations" do
    it "aceita uma única conversa não closed por lojista" do
      Tenancy.with_brand(infinitepay) do
        first = Conversation.create!(contact: contact, channel: "whatsapp")

        expect { in_savepoint { Conversation.create!(contact: contact, channel: "email") } }
          .to raise_error(ActiveRecord::RecordNotUnique)

        first.update_columns(state: "closed")
        expect(Conversation.create!(contact: contact, channel: "email")).to be_persisted
      end
    end
  end

  describe "messages" do
    def message_attributes(**attributes)
      { channel: "whatsapp", author: "customer", body: "oi" }.merge(attributes)
    end

    it "external_id é único por marca e canal" do
      Tenancy.with_brand(infinitepay) do
        conversation = Conversation.create!(contact: contact, channel: "whatsapp")
        conversation.append_message!(message_attributes(external_id: "wamid.1"))

        expect { conversation.append_message!(message_attributes(external_id: "wamid.1")) }
          .to raise_error(ActiveRecord::RecordNotUnique)
        expect(conversation.append_message!(message_attributes(channel: "email", external_id: "wamid.1"))).to be_persisted
        expect(conversation.append_message!(message_attributes(external_id: nil))).to be_persisted
        expect(conversation.append_message!(message_attributes(external_id: nil))).to be_persisted
      end
    end

    it "a chave estrangeira de brand_channel_id recusa o canal de outra marca" do
      Tenancy.with_brand(infinitepay) do
        conversation = Conversation.create!(contact: contact, channel: "whatsapp")

        expect(conversation.append_message!(message_attributes(brand_channel_id: brand_channel(infinitepay, "whatsapp").id)))
          .to be_persisted
        expect { conversation.append_message!(message_attributes(brand_channel_id: brand_channel(jim, "whatsapp").id)) }
          .to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end

    it "valida o formato dos anexos" do
      Tenancy.with_brand(infinitepay) do
        conversation = Conversation.create!(contact: contact, channel: "whatsapp")

        expect(conversation.append_message!(message_attributes(attachments: [ { kind: "image", size: 10 } ])).attachments)
          .to eq([ { "kind" => "image", "size" => 10 } ])
        expect { conversation.append_message!(message_attributes(attachments: [ { filename: "a.pdf" } ])) }
          .to raise_error(ActiveRecord::RecordInvalid)
        expect { conversation.append_message!(message_attributes(attachments: [ { kind: "image", url: "x" } ])) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe Channels::Identity do
    it "normaliza telefone em E.164 com +, e-mail em minúsculas e id do app sem espaços" do
      expect(described_class.normalize("whatsapp", "16505551234")).to eq("+16505551234")
      expect(described_class.normalize("whatsapp", "+55 (11) 91234-5678")).to eq("+5511912345678")
      expect(described_class.normalize("email", "  Lojista@Example.COM ")).to eq("lojista@example.com")
      expect(described_class.normalize("chat", " app-AbC ")).to eq("app-AbC")
      expect(described_class.normalize("whatsapp", "")).to be_nil
    end
  end
end

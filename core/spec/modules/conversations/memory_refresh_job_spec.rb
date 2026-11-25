require "rails_helper"

RSpec.describe Conversations::MemoryRefreshJob do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact_in_segment(brand, "alto_tpv") }

  def resolved_conversation
    conversation = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"))
    ).first.conversation
    resolve_conversation(brand, conversation.id, 1.hour.ago)
  end

  it "fica na fila default" do
    expect(described_class.new.queue_name).to eq("default")
  end

  it "abre a marca do job e grava a memória do lojista" do
    conversation = resolved_conversation

    described_class.perform_now(brand_id: brand.id, contact_id: contact.id, conversation_id: conversation.id)

    memory = Tenancy.with_brand(brand) { CustomerMemory.find_by!(contact_id: contact.id) }
    expect(memory.entries.sole).to include("channel" => "whatsapp", "category" => "repasse")
    event = Tenancy.with_brand(brand) { AuditEvent.find_by!(action: "customer_memory.updated") }
    expect(event.conversation_id).to eq(conversation.id)
  end

  it "não encontra o lojista com a marca de outro job" do
    conversation = resolved_conversation

    expect do
      described_class.perform_now(brand_id: jim.id, contact_id: contact.id, conversation_id: conversation.id)
    end.to raise_error(ActiveRecord::RecordNotFound)
    expect(Tenancy.with_brand(brand) { CustomerMemory.where(contact_id: contact.id).count }).to eq(0)
  end

  # As travas ficam em duas conexões, com commit de verdade; o exemplo roda fora da transação do
  # RSpec e apaga o que grava.
  describe "com a conversa travada por outra transação" do
    self.use_transactional_tests = false

    let(:conversation_ids) { [] }

    after do
      Tenancy.with_brand(brand) { CustomerMemory.where(contact_id: contact.id).delete_all }
      purge_conversations(brand, conversation_ids)
    end

    # pg_locks é lida de novo a cada consulta, mesmo dentro de uma transação.
    def job_waiting?
      ApplicationRecord.connection.select_value("SELECT count(*) FROM pg_locks WHERE NOT granted").to_i.positive?
    end

    it "espera a conversa sem segurar o lojista" do
      conversation = resolved_conversation
      conversation_ids << conversation.id

      job = nil
      Tenancy.with_brand(brand) do
        Conversation.lock.find(conversation.id)
        job = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            described_class.perform_now(brand_id: brand.id, contact_id: contact.id, conversation_id: conversation.id)
          end
        end
        Timeout.timeout(10) { sleep 0.05 until job_waiting? }

        ApplicationRecord.connection.execute("SET LOCAL lock_timeout = '2s'")
        expect(Contact.lock.find(contact.id)).to eq(contact)
      end
      job.join

      expect(Tenancy.with_brand(brand) { CustomerMemory.find_by(contact_id: contact.id) }).to be_present
    end
  end
end

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
end

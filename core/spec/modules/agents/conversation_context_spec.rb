require "rails_helper"

RSpec.describe Agents::ConversationContext do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }

  def customer_writes(text)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"), text: text)
    ).first.conversation
  end

  it "devolve a conversa e o histórico em ordem crescente de sequence, conforme o schema context" do
    conversation = customer_writes("Minha maquininha não liga")
    Tenancy.with_brand(brand) do
      Conversations::Outbound.append!(conversation: Conversation.find(conversation.id), author: "ai",
                                      text: "Vamos verificar.", in_reply_to_sequence: 1,
                                      attendant: Attendant.first_ai)
    end
    customer_writes("Ainda não liga")

    body = Tenancy.with_brand(brand) { described_class.call(conversation.id) }

    expect(Contract::Schemas.errors("context", body)).to eq([])
    expect(body.fetch("conversation")).to eq(
      "id" => conversation.id, "brand" => "infinitepay", "channel" => "whatsapp", "state" => "with_ai",
      "last_sequence" => 3
    )
    expect(body.fetch("messages").map { |message| message.values_at("sequence", "author", "text") }).to eq(
      [ [ 1, "customer", "Minha maquininha não liga" ], [ 2, "ai", "Vamos verificar." ], [ 3, "customer", "Ainda não liga" ] ]
    )
    expect(body.fetch("customer_memory")).to be_nil
  end

  it "não lê a conversa de outra marca" do
    conversation = customer_writes("Minha maquininha não liga")

    expect { Tenancy.with_brand(jim) { described_class.call(conversation.id) } }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end

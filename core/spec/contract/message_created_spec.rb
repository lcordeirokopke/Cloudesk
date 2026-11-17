require "rails_helper"

# Liga a F2 ao contrato: o envelope gravado pelo serviço de comando vira um webhook que segue o schema.
RSpec.describe Contract::MessageCreated do
  after { Current.reset }

  def create_event
    Audit::Command.call(brand: infinitepay, type: "message.created", actor_type: "customer", webhook: true) do |change|
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")
      message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "Meu repasse não caiu")
      change.target = message
      change.conversation = conversation
      change.sequence = message.sequence
      change.payload = { message: { author: "customer", channel: "whatsapp", text: "Meu repasse não caiu" } }
    end
  end

  it "monta, a partir do envelope do evento, um webhook que segue o contrato" do
    result = create_event

    body = described_class.build(result.audit_event.payload)

    expect(Contract::Schemas.errors("webhook.message-created", body)).to eq([])
    expect(body).to include(
      "event_id" => result.audit_event.event_id,
      "type" => "message.created",
      "brand" => "infinitepay",
      "conversation_id" => result.audit_event.conversation_id,
      "sequence" => 1,
      "message" => { "author" => "customer", "channel" => "whatsapp", "text" => "Meu repasse não caiu" },
      "context_url" => "/api/v1/agent/conversations/#{result.audit_event.conversation_id}/context",
      "traceparent" => result.envelope.traceparent.to_s
    )
  end

  it "recusa envelope de outro tipo de evento" do
    expect { described_class.build("type" => "conversation.routed") }.to raise_error(ArgumentError)
  end

  it "recusa envelope que não forma um webhook dentro do contrato" do
    envelope = create_event.audit_event.payload.merge("sequence" => nil)

    expect { described_class.build(envelope) }.to raise_error(Contract::Schemas::InvalidPayload)
  end
end

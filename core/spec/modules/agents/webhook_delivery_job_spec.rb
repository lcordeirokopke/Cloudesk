require "rails_helper"

RSpec.describe Agents::WebhookDeliveryJob do
  let(:brand) { infinitepay }

  after { Current.reset }

  def create_event
    Audit::Command.call(brand: brand, type: "message.created", actor_type: "customer", webhook: true) do |change|
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")
      message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
      change.target = message
      change.conversation = conversation
      change.sequence = message.sequence
      change.payload = { message: { author: "customer", channel: "whatsapp", text: "oi" } }
    end
  end

  it "usa a fila webhooks" do
    expect(described_class.new.queue_name).to eq("webhooks")
  end

  it "lê o envelope do evento na marca do job" do
    result = create_event

    envelope = described_class.new.load_envelope(brand.id, result.envelope.event_id)

    expect(envelope.to_h).to eq(result.envelope.to_h)
  end

  it "não lê o evento com a marca errada" do
    result = create_event

    expect { described_class.new.load_envelope(jim.id, result.envelope.event_id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "continua o trace do evento ao executar" do
    result = create_event
    job = described_class.new

    expect do
      job.perform(brand_id: brand.id, event_id: result.envelope.event_id, traceparent: result.envelope.traceparent.to_s)
    end.to raise_error(NotImplementedError)

    expect(Current.traceparent.trace_id).to eq(result.envelope.trace_id)
  end
end

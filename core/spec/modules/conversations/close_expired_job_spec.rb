require "rails_helper"

RSpec.describe Conversations::CloseExpiredJob do
  def resolved_conversation(brand, index, resolved_at)
    contact = seed_contact(brand, index)
    received = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"))
    ).first

    resolve_conversation(brand, received.conversation.id, resolved_at)
  end

  def state_of(brand, conversation)
    Tenancy.with_brand(brand) { Conversation.find(conversation.id).state }
  end

  it "fecha só as conversas resolvidas com prazo vencido, em cada marca, com conversation.closed" do
    expired_ip = resolved_conversation(infinitepay, 1, 25.hours.ago)
    recent_ip = resolved_conversation(infinitepay, 2, 1.hour.ago)
    expired_jim = resolved_conversation(jim, 1, 2.days.ago)
    open_ip = Conversations::Intake.call(
      inbound_message(brand: infinitepay, channel: "whatsapp", identity: identity_of(seed_contact(infinitepay, 3), "whatsapp"))
    ).first.conversation
    open_state = state_of(infinitepay, open_ip)

    described_class.perform_now

    expect(state_of(infinitepay, expired_ip)).to eq("closed")
    expect(state_of(jim, expired_jim)).to eq("closed")
    expect(state_of(infinitepay, recent_ip)).to eq("resolved")
    expect(state_of(infinitepay, open_ip)).to eq(open_state)

    event = audit_events_of(infinitepay, expired_ip.id).last
    expect(event).to have_attributes(action: "conversation.closed", actor_type: "system",
                                     before: { "state" => "resolved" }, after: { "state" => "closed" })
    expect(audit_events_of(jim, expired_jim.id).last.action).to eq("conversation.closed")
    expect(audit_events_of(infinitepay, recent_ip.id).map(&:action)).not_to include("conversation.closed")
  end

  it "usa o prazo de cada marca" do
    conversation = resolved_conversation(infinitepay, 1, 30.minutes.ago)
    allow(Brand).to receive(:find_each).and_wrap_original do |original, *arguments, &block|
      original.call(*arguments) do |brand|
        brand.reopen_window_minutes = 15 if brand.slug == "infinitepay"
        block.call(brand)
      end
    end

    described_class.perform_now

    expect(state_of(infinitepay, conversation)).to eq("closed")
  end
end

require "rails_helper"
require "rake"

# Task memory:demo_close: leva uma conversa resolved a closed para a demonstração da memória.
RSpec.describe "memory:demo_close" do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("memory:demo_close")
  end

  around do |example|
    previous = ENV["CONVERSATION"]
    example.run
  ensure
    ENV["CONVERSATION"] = previous
  end

  def run_task(conversation_id)
    ENV["CONVERSATION"] = conversation_id
    task = Rake::Task["memory:demo_close"]
    task.reenable
    task.invoke
  end

  def open_conversation
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"))
    ).first.conversation
  end

  it "leva a conversa resolved a closed com conversation.closed e ator operator" do
    conversation = open_conversation
    resolve_conversation(brand, conversation.id, 1.minute.ago)

    expect { run_task(conversation.id) }.to output(/#{conversation.id} em closed/).to_stdout

    Tenancy.with_brand(brand) { expect(Conversation.find(conversation.id).state).to eq("closed") }
    event = audit_events_of(brand, conversation.id).find { |audit_event| audit_event.action == "conversation.closed" }
    expect(event).to have_attributes(actor_type: "operator", reason: "demonstração", before: { "state" => "resolved" },
                                     after: { "state" => "closed" })
    expect(brand.reload.reopen_window_minutes).to eq(1440)
  end

  it "recusa a conversa fora de resolved, sem gravar nada" do
    conversation = open_conversation

    expect { run_task(conversation.id) }.to raise_error(ArgumentError, /está em #{conversation.state}/)
    expect(audit_events_of(brand, conversation.id).map(&:action)).not_to include("conversation.closed")
  end

  it "recusa o id inexistente e a falta de CONVERSATION" do
    expect { run_task(SecureRandom.uuid_v7) }.to raise_error(ArgumentError, /não encontrada/)
    expect { run_task("") }.to raise_error(ArgumentError, /informe CONVERSATION/)
  end
end

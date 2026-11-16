require "rails_helper"

RSpec.describe Conversation do
  ALLOWED = [
    %w[triage with_ai],
    %w[triage awaiting_human],
    %w[with_ai awaiting_human],
    %w[with_ai resolved],
    %w[with_ai triage],
    %w[awaiting_human with_human],
    %w[with_human resolved],
    %w[resolved triage],
    %w[resolved closed]
  ].freeze

  # Caminho de transições válidas que leva de triage até cada estado.
  PATHS = {
    "triage" => [],
    "with_ai" => %w[with_ai],
    "awaiting_human" => %w[awaiting_human],
    "with_human" => %w[awaiting_human with_human],
    "resolved" => %w[with_ai resolved],
    "closed" => %w[with_ai resolved closed]
  }.freeze

  def conversation_in(state)
    conversation = described_class.create!(contact: Contact.first!, channel: "whatsapp")
    PATHS.fetch(state).each { |step| conversation.transition_to!(step) }
    conversation
  end

  around { |example| Tenancy.with_brand(infinitepay) { example.run } }

  it "abre em triage, com last_sequence zero" do
    conversation = described_class.create!(contact: Contact.first!, channel: "email")

    expect(conversation.reload).to have_attributes(state: "triage", last_sequence: 0, priority: 0)
  end

  it "recusa a abertura em outro estado" do
    conversation = described_class.new(contact: Contact.first!, channel: "email", state: "with_ai")

    expect(conversation).not_to be_valid
  end

  it "tem exatamente as transições da tabela" do
    pairs = described_class::TRANSITIONS.flat_map { |from, targets| targets.map { |to| [ from, to ] } }

    expect(pairs).to match_array(ALLOWED)
    expect(described_class::TRANSITIONS.keys).to match_array(described_class::STATES)
  end

  ALLOWED.each do |from, to|
    it "aceita #{from} -> #{to}" do
      conversation = conversation_in(from)

      conversation.transition_to!(to)

      expect(conversation.reload.state).to eq(to)
    end
  end

  (described_class::STATES.product(described_class::STATES) - ALLOWED).each do |from, to|
    it "rejeita #{from} -> #{to}" do
      conversation = conversation_in(from)

      expect { conversation.transition_to!(to) }.to raise_error(described_class::InvalidTransition)
      expect(conversation.update(state: to)).to be(from == to)
      expect(conversation.reload.state).to eq(from)
    end
  end

  it "o banco recusa um estado fora do enum" do
    conversation = conversation_in("triage")

    expect_database_error(/invalid input value for enum conversation_state/) do
      described_class.where(id: conversation.id).update_all(state: "archived")
    end
  end
end

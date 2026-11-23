require "rails_helper"

RSpec.describe Observability::CockpitReader do
  let(:brand) { infinitepay }
  let(:registry) { Observability::Registry.build }
  let(:reader) { described_class.new(registry: registry) }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def value(name, **labels)
    registry.value(name, labels)
  end

  # Fila só do exemplo, para as séries por fila não somarem conversas de outros testes.
  def test_queue(target = brand, name: "obs-#{SecureRandom.hex(4)}", sla_minutes: 10, first_attendant: "ai")
    in_brand(target) do
      Routing::Queue.create!(name: name, sla_minutes: sla_minutes, capacity: 50, first_attendant: first_attendant)
    end
  end

  # Conversa do lojista na fila do exemplo, no estado informado, com a mensagem do lojista criada em
  # customer_at e, para awaiting_human, queued_at.
  def conversation_in(queue, state:, index: 0, target: brand, customer_at: Time.current, queued_at: nil,
                      sla_minutes: queue.sla_minutes)
    in_brand(target) do
      contact = Contact.order(:id).offset(index).first!
      Conversation.where(contact_id: contact.id).where.not(state: "closed").find_each do |open|
        open.update_columns(state: "closed")
      end
      conversation = Conversation.create!(contact: contact, channel: "whatsapp")
      conversation.update_columns(state: state, queue_id: queue.id, sla_minutes: sla_minutes, queued_at: queued_at)
      travel_to(customer_at, with_usec: true) do
        conversation.append_message!(channel: "whatsapp", author: "customer", body: "Minha maquininha não liga")
      end
      conversation.reload
    end
  end

  def ai_message(conversation, target: brand)
    in_brand(target) { Conversation.find(conversation.id).append_message!(channel: "whatsapp", author: "ai", body: "Olá") }
  end

  def resolved_event(conversation, actor_type:, at: Time.current, target: brand)
    travel_to(at, with_usec: true) do
      Audit::Command.call(brand: target, type: "conversation.resolved", actor_type: actor_type) do |change|
        change.target = conversation
        change.conversation = conversation
      end
    end
  end

  def handoff(conversation, reason:, at: Time.current, target: brand)
    travel_to(at, with_usec: true) do
      in_brand(target) { Handoff.create!(conversation_id: conversation.id, reason: reason, summary: "Resumo", context: {}) }
    end
  end

  def series(name)
    registry[name].values.transform_keys { |labels| labels.transform_keys(&:to_s) }
  end

  it "conta as conversas abertas por fila e estado" do
    queue = test_queue
    conversation_in(queue, state: "with_ai", index: 0)
    conversation_in(queue, state: "with_ai", index: 1)
    conversation_in(queue, state: "awaiting_human", index: 2, queued_at: Time.current)
    conversation_in(queue, state: "with_human", index: 3)
    conversation_in(queue, state: "resolved", index: 4)

    reader.collect

    labels = { brand: "infinitepay", queue: queue.name }
    expect(value(:cloudesk_conversations_open, **labels, state: "with_ai")).to eq(2)
    expect(value(:cloudesk_conversations_open, **labels, state: "awaiting_human")).to eq(1)
    expect(value(:cloudesk_conversations_open, **labels, state: "with_human")).to eq(1)
    expect(series(:cloudesk_conversations_open).keys.map { |item| item["state"] }.uniq - described_class::OPEN_STATES).to eq([])
  end

  it "classifica with_ai em at_risk e breached pela última mensagem do lojista sem resposta ai" do
    queue = test_queue(sla_minutes: 10)
    conversation_in(queue, state: "with_ai", index: 0, customer_at: 4.minutes.ago)
    conversation_in(queue, state: "with_ai", index: 1, customer_at: 6.minutes.ago)
    conversation_in(queue, state: "with_ai", index: 2, customer_at: 11.minutes.ago)
    answered = conversation_in(queue, state: "with_ai", index: 3, customer_at: 11.minutes.ago)
    ai_message(answered)

    reader.collect

    labels = { brand: "infinitepay", queue: queue.name }
    expect(value(:cloudesk_conversations_sla, **labels, level: "at_risk")).to eq(1)
    expect(value(:cloudesk_conversations_sla, **labels, level: "breached")).to eq(1)
  end

  it "classifica awaiting_human pelo tempo desde queued_at" do
    queue = test_queue(sla_minutes: 10, first_attendant: "human")
    conversation_in(queue, state: "awaiting_human", index: 0, customer_at: 30.minutes.ago, queued_at: 2.minutes.ago)
    conversation_in(queue, state: "awaiting_human", index: 1, customer_at: 30.minutes.ago, queued_at: 5.minutes.ago)
    conversation_in(queue, state: "awaiting_human", index: 2, customer_at: 30.minutes.ago, queued_at: 10.minutes.ago)

    reader.collect

    labels = { brand: "infinitepay", queue: queue.name }
    expect(value(:cloudesk_conversations_sla, **labels, level: "at_risk")).to eq(1)
    expect(value(:cloudesk_conversations_sla, **labels, level: "breached")).to eq(1)
  end

  it "mede a contenção: IA sem handoff anterior conta; IA com handoff anterior, analista e fora das 24 h não contam" do
    reader.collect
    resolved_before = value(:cloudesk_conversations_resolved_24h, brand: "infinitepay")
    by_ai_before = value(:cloudesk_conversations_resolved_by_ai_24h, brand: "infinitepay")
    queue = test_queue

    contained = conversation_in(queue, state: "resolved", index: 0)
    resolved_event(contained, actor_type: "ai")

    escalated = conversation_in(queue, state: "resolved", index: 1)
    handoff(escalated, reason: "transacao_contestada", at: 10.minutes.ago)
    resolved_event(escalated, actor_type: "ai")

    by_analyst = conversation_in(queue, state: "resolved", index: 2)
    resolved_event(by_analyst, actor_type: "analyst")

    handoff_after = conversation_in(queue, state: "resolved", index: 3)
    resolved_event(handoff_after, actor_type: "ai", at: 10.minutes.ago)
    handoff(handoff_after, reason: "ai_timeout", at: 5.minutes.ago)

    old = conversation_in(queue, state: "resolved", index: 4)
    resolved_event(old, actor_type: "ai", at: 25.hours.ago)

    reader.collect

    expect(value(:cloudesk_conversations_resolved_24h, brand: "infinitepay") - resolved_before).to eq(4)
    expect(value(:cloudesk_conversations_resolved_by_ai_24h, brand: "infinitepay") - by_ai_before).to eq(2)
  end

  it "conta os handoffs das últimas 24 h por motivo" do
    reader.collect
    before = series(:cloudesk_handoffs_24h)
    queue = test_queue
    first = conversation_in(queue, state: "awaiting_human", index: 0, queued_at: Time.current)
    second = conversation_in(queue, state: "awaiting_human", index: 1, queued_at: Time.current)
    handoff(first, reason: "obs_motivo_a")
    handoff(second, reason: "obs_motivo_a")
    handoff(second, reason: "obs_motivo_b")
    handoff(first, reason: "obs_motivo_c", at: 25.hours.ago)

    reader.collect

    expect(before.keys.map { |labels| labels["reason"] }).not_to include("obs_motivo_a")
    expect(value(:cloudesk_handoffs_24h, brand: "infinitepay", reason: "obs_motivo_a")).to eq(2)
    expect(value(:cloudesk_handoffs_24h, brand: "infinitepay", reason: "obs_motivo_b")).to eq(1)
    expect(series(:cloudesk_handoffs_24h).keys.map { |labels| labels["reason"] }).not_to include("obs_motivo_c")
  end

  it "volta a 0 as séries que somem" do
    queue = test_queue
    conversation = conversation_in(queue, state: "with_ai", index: 0, customer_at: 6.minutes.ago)
    reader.collect
    labels = { brand: "infinitepay", queue: queue.name }
    expect(value(:cloudesk_conversations_open, **labels, state: "with_ai")).to eq(1)
    expect(value(:cloudesk_conversations_sla, **labels, level: "at_risk")).to eq(1)

    in_brand { Conversation.find(conversation.id).update_columns(state: "resolved") }
    reader.collect

    expect(value(:cloudesk_conversations_open, **labels, state: "with_ai")).to eq(0)
    expect(value(:cloudesk_conversations_sla, **labels, level: "at_risk")).to eq(0)
  end

  it "separa as marcas pelo label brand" do
    ip_queue = test_queue(brand, name: "obs-mesmo-nome")
    jim_queue = test_queue(jim, name: "obs-mesmo-nome")
    conversation_in(ip_queue, target: brand, state: "with_ai", index: 0)
    conversation_in(jim_queue, target: jim, state: "with_ai", index: 0)
    conversation_in(jim_queue, target: jim, state: "with_ai", index: 1)

    reader.collect

    expect(value(:cloudesk_conversations_open, brand: "infinitepay", queue: "obs-mesmo-nome", state: "with_ai")).to eq(1)
    expect(value(:cloudesk_conversations_open, brand: "jim", queue: "obs-mesmo-nome", state: "with_ai")).to eq(2)
  end
end

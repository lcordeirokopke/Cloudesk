require "rails_helper"

RSpec.describe Conversations::MemoryRefresh do
  let(:brand) { infinitepay }
  # Repasse de lojista alto_tpv: fila de IA ip-financeiro-prioritaria.
  let(:contact) { seed_contact_in_segment(brand, "alto_tpv") }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  # Conversa nova do lojista, encerrada com os atributos informados. O resolved_at fica fora do prazo
  # de reabertura, então a próxima mensagem do lojista fecha esta conversa e abre outra.
  def finished_conversation(text: "Meu repasse de ontem não caiu", channel: "whatsapp", resolved_at: 3.days.ago,
                            attendant: nil, category: :keep, handoff: nil, of: contact, target: brand)
    conversation = Conversations::Intake.call(
      inbound_message(brand: target, channel: channel, identity: identity_of(of, channel), text: text)
    ).first.conversation
    in_brand(target) do
      Handoff.create!(conversation_id: conversation.id, reason: handoff, summary: "Resumo") if handoff
      attributes = { state: "resolved", resolved_at: resolved_at, attendant_id: (attendant || Attendant.first_ai).id }
      attributes[:category] = category unless category == :keep
      Conversation.where(id: conversation.id).update_all(attributes)
      Conversation.find(conversation.id)
    end
  end

  def refresh(conversation, of: contact, target: brand)
    in_brand(target) { described_class.call(brand: target, contact_id: of.id, conversation: conversation) }
  end

  def memory_of(of = contact, target = brand)
    in_brand(target) { CustomerMemory.find_by(contact_id: of.id) }
  end

  def memory_events(target = brand)
    in_brand(target) { AuditEvent.where(action: %w[customer_memory.updated customer_memory.deleted]).order(:created_at, :id).to_a }
  end

  def analyst
    in_brand { Attendant.where(kind: "human").order(:name).first! }
  end

  it "cria a memória da primeira conversa encerrada, com customer_memory.updated" do
    conversation = finished_conversation(resolved_at: Time.utc(2026, 11, 13, 15, 0, 0))

    memory = refresh(conversation)

    expect(memory.entries).to eq([ {
      "category" => "repasse", "channel" => "whatsapp", "resolved_by" => "ai",
      "resolved_at" => "2026-11-13T15:00:00.000Z", "handoff_reason" => nil,
      "first_message" => "Meu repasse de ontem não caiu"
    } ])
    expect(memory.summary).to eq('13/11/2026 · WhatsApp · repasse · resolvida pela IA · "Meu repasse de ontem não caiu"')
    event = memory_events.sole
    expect(event).to have_attributes(action: "customer_memory.updated", actor_type: "system", target_type: "CustomerMemory",
                                     target_id: memory.id, conversation_id: conversation.id, before: nil)
    expect(event.after).to eq("summary" => memory.summary, "entries" => memory.entries)
  end

  it "mostra o handoff, a falta de categoria e o analista na linha" do
    conversation = finished_conversation(resolved_at: Time.utc(2026, 11, 13, 15, 0, 0), attendant: analyst,
                                         category: nil, handoff: "repasse_nao_localizado")

    memory = refresh(conversation)

    expect(memory.entries.sole).to include("category" => nil, "resolved_by" => "analyst",
                                           "handoff_reason" => "repasse_nao_localizado")
    expect(memory.summary).to eq(
      '13/11/2026 · WhatsApp · sem categoria · resolvida por analista · escalada: repasse_nao_localizado · ' \
      '"Meu repasse de ontem não caiu"'
    )
  end

  it "guarda as 5 conversas resolvidas mais recentemente, da mais nova para a mais antiga" do
    conversations = (1..6).map do |day|
      finished_conversation(text: "Repasse #{day}", resolved_at: Time.utc(2026, 11, day, 12, 0, 0))
    end

    memory = refresh(conversations.last)

    expect(memory.entries.map { |entry| entry["first_message"] }).to eq([ "Repasse 6", "Repasse 5", "Repasse 4", "Repasse 3", "Repasse 2" ])
    expect(memory.summary.lines.size).to eq(5)
  end

  it "corta a primeira mensagem em 80 caracteres, com os espaços normalizados" do
    text = "Meu   repasse\n" + ("de ontem não caiu " * 10)
    conversation = finished_conversation(text: text)

    first_message = refresh(conversation).entries.sole.fetch("first_message")

    expect(first_message.length).to eq(80)
    expect(first_message).to start_with("Meu repasse de ontem").and end_with("...")
  end

  it "escreve no locale do lojista" do
    jim_contact = seed_contact_in_segment(jim, "high_tpv")
    conversation = finished_conversation(text: "My payout did not arrive", channel: "email", of: jim_contact, target: jim,
                                         resolved_at: Time.utc(2026, 11, 13, 15, 0, 0), handoff: "repasse_nao_localizado")

    memory = refresh(conversation, of: jim_contact, target: jim)

    expect(memory.summary).to eq(
      '11/13/2026 · Email · payout · resolved by the AI · escalated: repasse_nao_localizado · "My payout did not arrive"'
    )
  end

  it "deixa de fora a conversa que não está encerrada" do
    first = finished_conversation(text: "Primeira")
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "chat", identity: identity_of(contact, "chat"), text: "Segunda")
    )

    memory = refresh(first)

    expect(memory.entries.map { |entry| entry["first_message"] }).to eq([ "Primeira" ])
  end

  it "não grava nada quando a memória não muda" do
    conversation = finished_conversation
    memory = refresh(conversation)

    again = refresh(conversation)

    expect(again).to eq(memory)
    expect(again.updated_at).to eq(memory.updated_at)
    expect(memory_events.size).to eq(1)
  end

  it "atualiza a memória com a conversa nova, com before e after" do
    first = finished_conversation(text: "Primeira", resolved_at: 5.days.ago)
    refresh(first)
    second = finished_conversation(text: "Segunda", resolved_at: 3.days.ago)

    memory = refresh(second)

    expect(memory.entries.map { |entry| entry["first_message"] }).to eq(%w[Segunda Primeira])
    event = memory_events.last
    expect(event).to have_attributes(action: "customer_memory.updated", conversation_id: second.id)
    expect(event.before.fetch("entries").map { |entry| entry["first_message"] }).to eq(%w[Primeira])
    expect(event.after.fetch("summary")).to eq(memory.summary)
  end

  it "apaga a memória quando não resta conversa encerrada" do
    conversation = finished_conversation
    memory = refresh(conversation)
    in_brand { Conversation.where(id: conversation.id).update_all(state: "triage") }

    expect(refresh(conversation)).to be_nil

    expect(memory_of).to be_nil
    event = memory_events.last
    expect(event).to have_attributes(action: "customer_memory.deleted", actor_type: "system", target_id: memory.id,
                                     after: nil)
    expect(event.before).to eq("summary" => memory.summary, "entries" => memory.entries)
  end

  it "não faz nada sem conversa encerrada e sem memória" do
    conversation = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"))
    ).first.conversation

    expect(refresh(conversation)).to be_nil
    expect(memory_events).to be_empty
  end

  it "não enxerga o lojista de outra marca" do
    conversation = finished_conversation

    expect { refresh(conversation, target: jim) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(memory_of).to be_nil
  end
end

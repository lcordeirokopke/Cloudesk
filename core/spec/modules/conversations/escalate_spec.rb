require "rails_helper"

RSpec.describe Conversations::Escalate do
  let(:brand) { infinitepay }
  let(:ai_attendant) { in_brand { Attendant.first_ai } }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def queue(name)
    in_brand { Routing::Queue.find_by!(name: name) }
  end

  # Conversa em with_ai na fila informada, de um lojista das seeds.
  def conversation_in(queue_name, contact_index: 0, priority: 90, sla_minutes: 15)
    in_brand do
      conversation = Conversation.create!(contact: seed_contact(brand, contact_index), channel: "whatsapp")
      conversation.update!(queue: Routing::Queue.find_by!(name: queue_name), priority: priority, sla_minutes: sla_minutes,
                           state: "with_ai", attendant_id: ai_attendant.id)
      conversation
    end
  end

  def escalate(conversation, **options)
    in_brand do
      described_class.call(conversation: Conversation.lock.find(conversation.id), reason: "pedido_do_lojista",
                           summary: "Lojista pede analista", context: { "intent" => "repasse" },
                           actor_type: "ai", actor_id: ai_attendant.id, **options)
    end
  end

  def escalated_event(conversation)
    audit_events_of(brand, conversation.id).select { |event| event.action == "conversation.escalated" }.sole
  end

  it "com fila de escalação: vai para ela, recebe o SLA dela e mantém a prioridade" do
    conversation = conversation_in("ip-financeiro-prioritaria")
    received_at = Time.utc(2026, 11, 20, 12, 0)

    Current.set(received_at: received_at) { escalate(conversation) }

    updated = in_brand { Conversation.find(conversation.id) }
    expect(updated).to have_attributes(state: "awaiting_human", attendant_id: nil, queue_id: queue("ip-financeiro").id,
                                       sla_minutes: 60, priority: 90, queued_at: received_at)
    event = escalated_event(conversation)
    expect(event.payload.fetch("payload")).to include(
      "from_queue" => "ip-financeiro-prioritaria", "to_queue" => "ip-financeiro", "moved" => true, "capacity" => 50
    )
    expect(event.before).to include("state" => "with_ai", "queue_id" => queue("ip-financeiro-prioritaria").id,
                                    "sla_minutes" => 15)
    expect(event.after).to include("state" => "awaiting_human", "queue_id" => queue("ip-financeiro").id,
                                   "sla_minutes" => 60, "attendant_id" => nil)
  end

  it "sem fila de escalação: fica na fila atual, com o SLA da conversa" do
    conversation = conversation_in("ip-suporte-geral", priority: 10, sla_minutes: 120)

    escalate(conversation)

    updated = in_brand { Conversation.find(conversation.id) }
    expect(updated).to have_attributes(state: "awaiting_human", queue_id: queue("ip-suporte-geral").id, sla_minutes: 120,
                                       priority: 10)
    expect(escalated_event(conversation).payload.fetch("payload")).to include(
      "from_queue" => "ip-suporte-geral", "to_queue" => "ip-suporte-geral", "moved" => false
    )
  end

  it "conta as conversas abertas do destino sem conferir a capacidade" do
    in_brand { Routing::Queue.find_by!(name: "ip-financeiro").update!(capacity: 1) }
    conversation_in("ip-financeiro", contact_index: 1)
    conversation = conversation_in("ip-financeiro-prioritaria")

    escalate(conversation)

    expect(in_brand { Conversation.find(conversation.id).queue.name }).to eq("ip-financeiro")
    expect(escalated_event(conversation).payload.fetch("payload")).to include("open_conversations" => 1, "capacity" => 1)
  end

  it "cria o handoff e grava o evento com ator, motivo e handoff_id" do
    conversation = conversation_in("ip-financeiro-prioritaria")

    handoff = escalate(conversation)

    expect(handoff).to have_attributes(conversation_id: conversation.id, reason: "pedido_do_lojista",
                                       summary: "Lojista pede analista", context: { "intent" => "repasse" })
    expect(escalated_event(conversation)).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id,
                                                             reason: "pedido_do_lojista")
    expect(escalated_event(conversation).payload.dig("payload", "handoff_id")).to eq(handoff.id)
  end

  it "atualiza o painel do analista com a equipe do destino" do
    conversation = conversation_in("ip-financeiro-prioritaria")
    before_jobs = jobs_of(Conversations::PanelBroadcastJob).count

    escalate(conversation)

    job = jobs_of(Conversations::PanelBroadcastJob).order(:id).last
    expect(jobs_of(Conversations::PanelBroadcastJob).count).to eq(before_jobs + 1)
    expect(job_arguments(job)).to include("conversation_id" => conversation.id, "team_id" => queue("ip-financeiro").team_id)
  end

  it "roda só dentro do Tenancy.with_brand da marca da conversa" do
    conversation = conversation_in("ip-financeiro-prioritaria")

    expect do
      described_class.call(conversation: conversation, reason: "r", summary: "s", context: {}, actor_type: "system")
    end.to raise_error(ArgumentError)
  end
end

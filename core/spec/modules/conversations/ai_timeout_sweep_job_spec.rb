require "rails_helper"

RSpec.describe Conversations::AiTimeoutSweepJob do
  let(:brand) { infinitepay }
  let(:start) { Time.utc(2026, 11, 20, 12, 0) }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  # Conversa da IA na fila geral (SLA da regra genérica: 120 min) aberta pela mensagem do lojista.
  def conversation_with_ai(target = brand, index: 0, text: "Minha maquininha não liga")
    contact = seed_contact(target, index)
    conversation = Conversations::Intake.call(
      inbound_message(brand: target, channel: "whatsapp", identity: identity_of(contact, "whatsapp"), text: text,
                      received_at: Time.current)
    ).first.conversation
    expect(conversation.state).to eq("with_ai")
    conversation
  end

  def set_sla(conversation, minutes, target = brand)
    in_brand(target) { Conversation.find(conversation.id).update!(sla_minutes: minutes) }
  end

  def messages_of(conversation, target = brand)
    in_brand(target) { Message.where(conversation_id: conversation.id).order(:sequence).to_a }
  end

  def reload(conversation, target = brand)
    in_brand(target) { Conversation.find(conversation.id) }
  end

  def ai_replies(conversation)
    in_brand do
      Conversations::Outbound.append!(conversation: Conversation.find(conversation.id), author: "ai", text: "Resposta",
                                      in_reply_to_sequence: 1, attendant: Attendant.first_ai)
    end
  end

  around { |example| travel_to(start) { example.run } }

  it "na metade do SLA, envia a mensagem de espera do sistema uma vez só" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)

    travel 4.minutes
    described_class.perform_now
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer])

    travel 1.minute
    described_class.perform_now
    travel 1.minute
    described_class.perform_now

    messages = messages_of(conversation)
    expect(messages.map(&:author)).to eq(%w[customer system])
    expect(messages.last).to have_attributes(channel: "whatsapp", body: "Estamos verificando sua solicitação, em instantes retornamos.")
    event = audit_events_of(brand, conversation.id).select { |e| e.action == "message.created" }.last
    expect(event).to have_attributes(actor_type: "system", reason: "ai_timeout_wait")
    expect(event.payload.dig("payload", "in_reply_to_sequence")).to eq(1)
    expect(reload(conversation).state).to eq("with_ai")
  end

  it "no SLA inteiro sem resposta da IA, escala com handoff ai_timeout, mesmo depois da espera" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)

    travel 5.minutes
    described_class.perform_now
    travel 5.minutes
    described_class.perform_now

    expect(reload(conversation)).to have_attributes(state: "awaiting_human", attendant_id: nil)
    handoff = in_brand { Handoff.where(conversation_id: conversation.id).sole }
    expect(handoff).to have_attributes(reason: "ai_timeout", summary: "A IA não respondeu em 10 min.", context: {})
    escalated = audit_events_of(brand, conversation.id).find { |e| e.action == "conversation.escalated" }
    expect(escalated).to have_attributes(actor_type: "system", actor_id: nil, reason: "ai_timeout")
  end

  it "passado o SLA sem espera, só escala" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)

    travel 11.minutes
    described_class.perform_now

    expect(reload(conversation).state).to eq("awaiting_human")
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer])
  end

  it "a resposta da IA cancela a espera e a escalação" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)
    ai_replies(conversation)

    travel 11.minutes
    described_class.perform_now

    expect(reload(conversation).state).to eq("with_ai")
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer ai])
  end

  it "o prazo conta da última mensagem do lojista" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)
    ai_replies(conversation)
    travel 8.minutes
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(seed_contact(brand), "whatsapp"),
                      text: "E agora?", received_at: Time.current)
    )

    travel 4.minutes
    described_class.perform_now
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer ai customer])

    travel 1.minute
    described_class.perform_now
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer ai customer system])
    expect(reload(conversation).state).to eq("with_ai")
  end

  it "ignora a conversa fora de with_ai" do
    conversation = conversation_with_ai
    set_sla(conversation, 10)
    in_brand { Conversation.find(conversation.id).update!(state: "resolved", resolved_at: Time.current) }

    travel 11.minutes
    described_class.perform_now

    expect(reload(conversation).state).to eq("resolved")
    expect(messages_of(conversation).map(&:author)).to eq(%w[customer])
  end

  it "trata cada marca com o seu locale" do
    ip = conversation_with_ai
    us = conversation_with_ai(jim, text: "My card reader does not turn on")
    set_sla(ip, 10)
    set_sla(us, 10, jim)

    travel 5.minutes
    described_class.perform_now

    expect(messages_of(ip).last.body).to eq("Estamos verificando sua solicitação, em instantes retornamos.")
    expect(messages_of(us, jim).last.body).to eq("We are checking your request and will get back to you shortly.")

    travel 5.minutes
    described_class.perform_now
    expect(in_brand(jim) { Handoff.where(conversation_id: us.id).sole.summary }).to eq("The AI did not respond within 10 min.")
  end

  # A trava fica com outra conexão, com commit de verdade; o exemplo roda fora da transação do
  # RSpec e apaga o que grava.
  describe "com a conversa travada" do
    self.use_transactional_tests = false

    let(:conversation_ids) { [] }

    after { purge_conversations(brand, conversation_ids) }

    it "pula a conversa travada" do
      conversation = conversation_with_ai(index: 45)
      conversation_ids << conversation.id
      set_sla(conversation, 10)
      locked = Thread::Queue.new
      release = Thread::Queue.new

      holder = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          in_brand do
            Conversation.lock.find(conversation.id)
            locked << true
            release.pop
          end
        end
      end
      locked.pop

      travel 11.minutes
      described_class.perform_now
      release << true
      holder.join

      expect(reload(conversation).state).to eq("with_ai")
      expect(messages_of(conversation).map(&:author)).to eq(%w[customer])
    end
  end
end

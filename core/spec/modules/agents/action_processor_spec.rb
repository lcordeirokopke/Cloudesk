require "rails_helper"

RSpec.describe Agents::ActionProcessor do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:ai_attendant) { in_brand { Attendant.first_ai } }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  # Mensagem do lojista pelo WhatsApp. O texto leva a conversa à fila geral, atendida pela IA.
  def customer_writes(text = "Minha maquininha não liga", from: contact)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(from, "whatsapp"), text: text)
    ).first
  end

  def conversation_with_ai(text = "Minha maquininha não liga")
    conversation = customer_writes(text).conversation
    expect(conversation.state).to eq("with_ai")
    conversation
  end

  def reload(conversation)
    in_brand { Conversation.find(conversation.id) }
  end

  def process(action, idempotency_key: Contract::IdempotencyKey.for_action(action))
    described_class.call(action: action, idempotency_key: idempotency_key)
  end

  def events(conversation, action)
    audit_events_of(brand, conversation.id).select { |audit_event| audit_event.action == action }
  end

  def expect_response_contract(result)
    expect(Contract::Schemas.errors("action-response", result.body)).to eq([])
  end

  describe "reply" do
    it "grava a resposta da IA, enfileira a entrega e responde accepted com a sequência da mensagem" do
      conversation = conversation_with_ai

      result = process(agent_action(conversation, text: "Vamos verificar sua maquininha."))

      expect(result.status).to eq(:ok)
      expect_response_contract(result)
      in_brand do
        message = Message.find_by!(conversation_id: conversation.id, sequence: 2)
        expect(message).to have_attributes(author: "ai", attendant_id: ai_attendant.id, channel: "whatsapp",
                                           body: "Vamos verificar sua maquininha.")
        expect(result.body).to eq(
          "status" => "accepted", "type" => "reply", "conversation_id" => conversation.id,
          "event_id" => events(conversation, "agent.reply").last.event_id, "message_sequence" => 2
        )
        expect(jobs_of(Channels::DeliveryJob).map { |job| job_arguments(job)["message_id"] }).to include(message.id)
      end
    end

    it "responde à última mensagem do lojista até o based_on_sequence" do
      conversation = conversation_with_ai
      process(agent_action(conversation))
      ai_event = events(conversation, "message.created").find { |event| event.payload.dig("payload", "message", "author") == "ai" }

      result = process(agent_action(conversation, inbound_event_id: ai_event.event_id, based_on_sequence: 2, text: "Algo mais?"))

      expect(result.body["message_sequence"]).to eq(3)
      reply_event = events(conversation, "message.created").last
      expect(reply_event.payload.dig("payload", "in_reply_to_sequence")).to eq(1)
    end

    it "grava no evento da ação o corpo completo, a Idempotency-Key, as ferramentas, o model e os carimbos" do
      conversation = conversation_with_ai
      action = agent_action(conversation, example: "reply-llm")

      process(action)

      event = events(conversation, "agent.reply").sole
      expect(event).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id, target_type: "Message")
      expect(event.payload).to include("type" => "agent.reply", "conversation_id" => conversation.id, "sequence" => 2)
      expect(event.payload.fetch("received_at")).to be_present
      expect(event.payload.fetch("payload")).to eq(
        "idempotency_key" => Contract::IdempotencyKey.for_action(action), "action" => action
      )
      expect(action.keys).to include("tools", "model", "timestamps")
    end
  end

  describe "idempotência" do
    it "a mesma ação enviada duas vezes produz um único efeito e a segunda recebe o corpo da primeira" do
      conversation = conversation_with_ai
      action = agent_action(conversation)

      first = process(action)
      second = process(action)

      expect(second.status).to eq(:ok)
      expect(second.body).to eq(first.body)
      in_brand { expect(Message.where(conversation_id: conversation.id, author: "ai").count).to eq(1) }
      expect(events(conversation, "agent.reply").size).to eq(1)
      in_brand { expect(ProcessedEvent.where(idempotency_key: Contract::IdempotencyKey.for_action(action)).count).to eq(1) }
    end

    it "aceita uma ação de cada tipo para o mesmo evento de entrada" do
      conversation = conversation_with_ai

      expect(process(agent_action(conversation, example: "categorize", category: "maquininha")).status).to eq(:ok)
      expect(process(agent_action(conversation)).status).to eq(:ok)
    end
  end

  describe "stale" do
    it "recusa com 409 a ação baseada em contexto desatualizado, grava o evento e repete o corpo sem novo evento" do
      conversation = conversation_with_ai
      action = agent_action(conversation)
      customer_writes("Ainda não liga")

      result = process(action)
      repeated = process(action)

      expect(result.status).to eq(:conflict)
      expect_response_contract(result)
      stale_event = events(conversation, "agent.action.stale").sole
      expect(result.body).to eq(
        "status" => "stale", "conversation_id" => conversation.id, "event_id" => stale_event.event_id,
        "based_on_sequence" => 1, "last_customer_sequence" => 2
      )
      expect(stale_event).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id)
      expect(stale_event.payload.fetch("payload")).to include("action" => action, "last_customer_sequence" => 2)
      expect(repeated.status).to eq(:conflict)
      expect(repeated.body).to eq(result.body)
      expect(events(conversation, "agent.action.stale").size).to eq(1)
      in_brand { expect(Message.where(conversation_id: conversation.id, author: "ai")).to be_empty }
    end

    it "vale para as quatro ações" do
      conversation = conversation_with_ai
      actions = [
        agent_action(conversation),
        agent_action(conversation, example: "escalate"),
        agent_action(conversation, example: "categorize", category: "maquininha"),
        agent_action(conversation, example: "resolve")
      ]
      customer_writes("Ainda não liga")

      expect(actions.map { |action| process(action).body["status"] }).to eq(%w[stale stale stale stale])
      expect(reload(conversation).state).to eq("with_ai")
    end
  end

  describe "rejected" do
    it "recusa com 409 a ação com a conversa fora de with_ai, com o estado e o atendente IA da marca como ator" do
      conversation = conversation_with_ai
      in_brand do
        Conversation.find(conversation.id).update!(state: "awaiting_human", attendant_id: nil)
        Conversation.find(conversation.id).update!(state: "with_human")
      end
      action = agent_action(conversation)

      result = process(action)
      repeated = process(action)

      expect(result.status).to eq(:conflict)
      expect_response_contract(result)
      rejected_event = events(conversation, "agent.action.rejected").sole
      expect(result.body).to eq(
        "status" => "rejected", "conversation_id" => conversation.id, "event_id" => rejected_event.event_id,
        "state" => "with_human"
      )
      expect(rejected_event).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id, reason: "conversa em with_human")
      expect(repeated.body).to eq(result.body)
      expect(events(conversation, "agent.action.rejected").size).to eq(1)
    end

    it "a recusa vem antes da conferência da sequência" do
      conversation = conversation_with_ai
      action = agent_action(conversation)
      in_brand do
        Conversation.find(conversation.id).update!(state: "awaiting_human", attendant_id: nil)
        Conversation.find(conversation.id).update!(state: "with_human")
      end
      customer_writes("Ainda não liga")

      expect(process(action).body).to include("status" => "rejected", "state" => "with_human")
    end

    it "recusa a ação depois do resolve" do
      conversation = conversation_with_ai
      process(agent_action(conversation, example: "resolve"))

      expect(process(agent_action(conversation)).body).to include("status" => "rejected", "state" => "resolved")
    end
  end

  describe "invalid_payload" do
    it "recusa com 422 o corpo fora do contrato, sem gravar nada" do
      conversation = conversation_with_ai
      action = agent_action(conversation).except("text")

      result = process(action, idempotency_key: "#{action['inbound_event_id']}:reply")

      expect(result.status).to eq(:unprocessable_content)
      expect(result.body).to include("status" => "error", "error" => "invalid_payload")
      expect_response_contract(result)
    end

    it "recusa a Idempotency-Key diferente da derivada do corpo" do
      action = agent_action(conversation_with_ai)

      result = process(action, idempotency_key: "#{action['inbound_event_id']}:resolve")

      expect(result.body).to include("error" => "invalid_payload")
    end

    it "recusa o inbound_event_id que não é um message.created da conversa" do
      conversation = conversation_with_ai
      other = conversation_with_ai_of(seed_contact(brand, 1))

      results = [
        process(agent_action(conversation, inbound_event_id: SecureRandom.uuid_v7)),
        process(agent_action(conversation, inbound_event_id: last_customer_event(other).event_id)),
        process(agent_action(conversation, inbound_event_id: events(conversation, "conversation.opened").sole.event_id))
      ]

      expect(results.map(&:status)).to eq([ :unprocessable_content ] * 3)
      in_brand { expect(ProcessedEvent.count).to eq(0) }
    end

    it "recusa o based_on_sequence maior que a última sequência da conversa" do
      conversation = conversation_with_ai

      result = process(agent_action(conversation, based_on_sequence: 2))

      expect(result.body).to include("error" => "invalid_payload")
      expect(result.body["message"]).to include("based_on_sequence")
    end

    def conversation_with_ai_of(other_contact)
      result = customer_writes(from: other_contact)
      result.conversation
    end
  end

  describe "not_found" do
    it "responde 404 para marca inexistente e para conversa de outra marca" do
      conversation = conversation_with_ai

      unknown_brand = process(agent_action(conversation, brand: "outra"))
      other_brand = process(agent_action(conversation, brand: "jim"))

      expect([ unknown_brand.status, other_brand.status ]).to eq([ :not_found, :not_found ])
      expect(other_brand.body).to include("error" => "not_found")
      expect_response_contract(other_brand)
    end
  end

  describe "escalate" do
    it "grava o handoff e leva a conversa a awaiting_human na fila atual, sem atendente e com queued_at" do
      conversation = conversation_with_ai
      action = agent_action(conversation, example: "escalate")

      result = process(action)

      expect(result.body).to include("status" => "accepted", "type" => "escalate", "message_sequence" => nil)
      updated = reload(conversation)
      expect(updated).to have_attributes(state: "awaiting_human", attendant_id: nil, queue_id: conversation.queue_id)
      expect(updated.queued_at).to be_present
      in_brand do
        expect(Handoff.where(conversation_id: conversation.id).sole).to have_attributes(
          reason: action["reason"], summary: action["summary"], context: action["context"]
        )
      end
      escalated = events(conversation, "conversation.escalated").sole
      expect(escalated).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id, reason: action["reason"])
      expect(escalated.before).to include("state" => "with_ai", "attendant_id" => ai_attendant.id)
      expect(escalated.after).to include("state" => "awaiting_human", "attendant_id" => nil)
      expect(events(conversation, "agent.escalate").sole.target_type).to eq("Conversation")
    end
  end

  describe "categorize" do
    it "roteia de novo pela categoria do agente e a conversa volta à IA" do
      conversation = conversation_with_ai

      result = process(agent_action(conversation, example: "categorize", category: "maquininha"))

      expect(result.body).to include("status" => "accepted", "type" => "categorize", "message_sequence" => nil)
      expect(reload(conversation)).to have_attributes(state: "with_ai", category: "maquininha")
      classified = events(conversation, "conversation.classified").last
      expect(classified).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id)
      expect(classified.payload.dig("payload", "trigger")).to eq("categorize")
      expect(events(conversation, "conversation.routed").last.payload.dig("payload", "trigger")).to eq("categorize")
    end

    it "com a conversa levada à fila humana, a ação seguinte do mesmo evento recebe rejected" do
      # repasse sem o segmento alto_tpv cai na regra da fila humana.
      conversation = customer_writes(from: seed_contact_in_segment(brand, "medio_tpv")).conversation

      process(agent_action(conversation, example: "categorize", category: "repasse"))
      reply = process(agent_action(conversation))

      expect(reload(conversation).state).to eq("awaiting_human")
      expect(reply.body).to include("status" => "rejected", "state" => "awaiting_human")
    end

    it "não reenvia o webhook ao Broker" do
      conversation = conversation_with_ai

      expect { process(agent_action(conversation, example: "categorize", category: "maquininha")) }
        .not_to(change { webhook_jobs.count })
    end
  end

  describe "resolve" do
    it "leva a conversa a resolved, grava resolved_at e mantém o atendente, sem mensagem ao lojista" do
      conversation = conversation_with_ai

      result = process(agent_action(conversation, example: "resolve"))

      expect(result.body).to include("status" => "accepted", "type" => "resolve", "message_sequence" => nil)
      updated = reload(conversation)
      expect(updated).to have_attributes(state: "resolved", attendant_id: ai_attendant.id)
      expect(updated.resolved_at).to be_present
      expect(events(conversation, "conversation.resolved").sole).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id)
      in_brand { expect(Message.where(conversation_id: conversation.id).count).to eq(1) }
    end
  end

  # Cada thread usa uma conexão e uma transação próprias, com commit de verdade; por isso os
  # exemplos rodam fora da transação do RSpec e apagam o que gravam.
  describe "com ações duplicadas simultâneas" do
    self.use_transactional_tests = false

    let(:contact) { seed_contact(brand, 30) }
    let(:conversation_ids) { [] }

    after do
      message_ids, event_ids, keys = in_brand do
        events = AuditEvent.where(conversation_id: conversation_ids)
        [
          Message.where(conversation_id: conversation_ids).pluck(:id),
          events.where(action: "message.created").pluck(:event_id),
          events.where(action: "agent.reply").map { |event| event.payload.dig("payload", "idempotency_key") }
        ]
      end
      purge_processed_events(keys)
      purge_conversations(brand, conversation_ids)
      SolidQueue::Job.where(class_name: [ "Channels::DeliveryJob", "Agents::WebhookDeliveryJob" ]).find_each do |job|
        arguments = job_arguments(job)
        job.destroy if message_ids.include?(arguments["message_id"]) || event_ids.include?(arguments["event_id"])
      end
    end

    def purge_processed_events(keys)
      return if keys.empty?

      connection = OwnerRecord.lease_connection
      OwnerRecord.transaction do
        connection.execute("SELECT set_config('app.brand_id', #{connection.quote(brand.id)}, true)")
        connection.execute("DELETE FROM processed_events WHERE idempotency_key IN (#{keys.map { |key| connection.quote(key) }.join(', ')})")
      end
    end

    it "só uma produz efeito e as duas recebem o mesmo corpo" do
      conversation = conversation_with_ai
      conversation_ids << conversation.id
      action = agent_action(conversation)
      barrier = Concurrent::CyclicBarrier.new(2)

      threads = 2.times.map do
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            barrier.wait(5)
            process(action)
          end
        end
      end
      results = threads.map(&:value)

      expect(results.map(&:status)).to eq([ :ok, :ok ])
      expect(results.map(&:body).uniq.size).to eq(1)
      in_brand { expect(Message.where(conversation_id: conversation.id, author: "ai").count).to eq(1) }
      expect(events(conversation, "agent.reply").size).to eq(1)
    end
  end
end

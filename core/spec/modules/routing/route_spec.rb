require "rails_helper"

RSpec.describe Routing::Route do
  let(:brand) { infinitepay }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def open_conversation(contact, channel: "whatsapp")
    in_brand { Conversation.create!(contact: contact, channel: channel) }
  end

  def route(conversation, text: "Meu repasse não caiu", **options)
    in_brand do
      described_class.call(conversation: Conversation.find(conversation.id), trigger: "intake", text: text, **options)
    end
  end

  def queue(name)
    in_brand { Routing::Queue.find_by!(name: name) }
  end

  def event(conversation, action)
    audit_events_of(brand, conversation.id).select { |audit_event| audit_event.action == action }.last
  end

  # Ocupa a fila com conversas abertas de outros lojistas das seeds, no estado informado.
  def occupy(queue_name, count, state: "with_ai")
    @occupied ||= 0
    count.times do
      in_brand do
        contact = Contact.where.not(id: [ alto.id, medio.id ]).order(:id).offset(@occupied).first!
        @occupied += 1
        conversation = Conversation.create!(contact: contact, channel: "chat")
        conversation.update!(queue: Routing::Queue.find_by!(name: queue_name),
                             state: state == "with_human" ? "awaiting_human" : state)
        conversation.update!(state: "with_human") if state == "with_human"
      end
    end
  end

  def set_capacity(queue_name, capacity)
    in_brand { Routing::Queue.find_by!(name: queue_name).update!(capacity: capacity) }
  end

  let(:alto) { seed_contact_in_segment(brand, "alto_tpv") }
  let(:medio) { seed_contact_in_segment(brand, "medio_tpv") }
  let(:ai_attendant) { in_brand { Attendant.find_by!(kind: "ai") } }

  describe "atribuição" do
    it "fila com atendente inicial ai: atendente IA da marca e with_ai" do
      result = route(open_conversation(alto))

      expect(result.routed).to be(true)
      expect(result.conversation).to have_attributes(state: "with_ai", attendant_id: ai_attendant.id, priority: 90,
                                                     sla_minutes: 15, queue_id: queue("ip-financeiro-prioritaria").id,
                                                     queued_at: nil)
    end

    it "só a atribuição à fila humana atualiza o painel do analista" do
      panel_jobs = -> { jobs_of(Conversations::PanelBroadcastJob).count }
      before_jobs = panel_jobs.call

      route(open_conversation(alto))
      expect(panel_jobs.call).to eq(before_jobs)

      route(open_conversation(medio))
      expect(panel_jobs.call).to eq(before_jobs + 1)
    end

    it "fila com atendente inicial human: awaiting_human, sem atendente, com queued_at" do
      received_at = Time.utc(2026, 11, 19, 12, 0)
      result = route(open_conversation(medio), received_at: received_at)

      expect(result.conversation).to have_attributes(state: "awaiting_human", attendant_id: nil, priority: 50,
                                                     sla_minutes: 60, queue_id: queue("ip-financeiro").id,
                                                     queued_at: received_at)
    end
  end

  describe "valores da regra e da fila" do
    it "sem sla_minutes e first_attendant na regra, valem os da fila" do
      in_brand do
        RoutingRule.create!(name: "Chat", position: 0, when: { "channel" => "chat" },
                            then: { "queue" => "ip-financeiro", "priority" => 70 })
      end

      result = route(open_conversation(alto, channel: "chat"))

      expect(result.conversation).to have_attributes(state: "awaiting_human", priority: 70, sla_minutes: 60)
    end

    it "com sla_minutes e first_attendant na regra, valem os da regra" do
      in_brand do
        RoutingRule.create!(name: "Chat", position: 0, when: { "channel" => "chat" },
                            then: { "queue" => "ip-financeiro", "priority" => 70, "sla_minutes" => 5, "first_attendant" => "ai" })
      end

      result = route(open_conversation(alto, channel: "chat"))

      expect(result.conversation).to have_attributes(state: "with_ai", priority: 70, sla_minutes: 5)
    end
  end

  describe "transbordo" do
    it "fila cheia transborda para a overflow_queue, com o SLA e o atendente inicial dela" do
      set_capacity("ip-financeiro-prioritaria", 2)
      occupy("ip-financeiro-prioritaria", 2)

      conversation = open_conversation(alto)
      result = route(conversation)

      expect(result.conversation).to have_attributes(state: "awaiting_human", priority: 90, sla_minutes: 60,
                                                     queue_id: queue("ip-financeiro").id)
      payload = event(conversation, "conversation.routed").payload.fetch("payload")
      expect(payload).to include("overflow" => true, "queue" => "ip-financeiro", "first_attendant" => "human")
      expect(payload["queue_chain"]).to eq([
        { "queue" => "ip-financeiro-prioritaria", "open_conversations" => 2, "capacity" => 2 },
        { "queue" => "ip-financeiro", "open_conversations" => 0, "capacity" => 50 }
      ])
    end

    it "conta todas as conversas abertas da fila: with_ai, awaiting_human e with_human" do
      set_capacity("ip-financeiro-prioritaria", 3)
      occupy("ip-financeiro-prioritaria", 1, state: "with_ai")
      occupy("ip-financeiro-prioritaria", 1, state: "awaiting_human")
      occupy("ip-financeiro-prioritaria", 1, state: "with_human")

      expect(route(open_conversation(alto)).queue.name).to eq("ip-financeiro")
    end

    it "segue a cadeia; no fim dela, a conversa entra na última fila" do
      set_capacity("ip-financeiro-prioritaria", 1)
      set_capacity("ip-financeiro", 1)
      occupy("ip-financeiro-prioritaria", 1)
      occupy("ip-financeiro", 1, state: "awaiting_human")

      conversation = open_conversation(alto)
      result = route(conversation)

      expect(result.queue.name).to eq("ip-financeiro")
      chain = event(conversation, "conversation.routed").payload.dig("payload", "queue_chain")
      expect(chain.map { |step| step["queue"] }).to eq(%w[ip-financeiro-prioritaria ip-financeiro])
    end

    it "uma cadeia em ciclo para na última fila ainda não visitada" do
      set_capacity("ip-financeiro-prioritaria", 1)
      set_capacity("ip-financeiro", 1)
      in_brand do
        Routing::Queue.find_by!(name: "ip-financeiro").update!(overflow_queue: Routing::Queue.find_by!(name: "ip-financeiro-prioritaria"))
      end
      occupy("ip-financeiro-prioritaria", 1)
      occupy("ip-financeiro", 1, state: "awaiting_human")

      expect(route(open_conversation(alto)).queue.name).to eq("ip-financeiro")
    end
  end

  describe "auditoria" do
    it "conversation.classified grava categoria, urgência, palavras e versão do classificador" do
      conversation = open_conversation(alto)
      route(conversation, text: "Repasse bloqueado")

      classified = event(conversation, "conversation.classified")
      expect(classified).to have_attributes(actor_type: "system", before: { "category" => nil, "urgency" => nil },
                                            after: { "category" => "repasse", "urgency" => "high" })
      expect(classified.payload.fetch("payload")).to eq(
        "trigger" => "intake", "category" => "repasse", "urgency" => "high",
        "matches" => { "category" => { "repasse" => [ "repasse" ] }, "urgency" => [ "bloqueado" ] },
        "scores" => { "repasse" => 2 }, "classifier_version" => 2
      )
    end

    it "conversation.routed grava a regra e a versão que casaram" do
      rule = in_brand { RoutingRule.find_by!(name: "InfinitePay · Repasse · Alto volume", version: 1) }
      conversation = open_conversation(alto)

      route(conversation)

      routed = event(conversation, "conversation.routed")
      expect(routed).to have_attributes(actor_type: "system", routing_rule_id: rule.id, rule_version: 1)
      expect(routed.before).to include("state" => "triage", "queue_id" => nil)
      expect(routed.after).to include("state" => "with_ai", "attendant_id" => ai_attendant.id, "priority" => 90)
      expect(routed.payload.fetch("payload")).to include(
        "trigger" => "intake", "queue" => "ip-financeiro-prioritaria", "priority" => 90, "sla_minutes" => 15,
        "first_attendant" => "ai", "overflow" => false,
        "rule" => { "id" => rule.id, "rule_id" => rule.rule_id, "version" => 1,
                    "name" => "InfinitePay · Repasse · Alto volume", "position" => 3 }
      )
    end

    it "grava a versão vigente quando a regra tem mais de uma" do
      rule_id = in_brand { RoutingRule.find_by!(name: "InfinitePay · Repasse · Alto volume").rule_id }
      version = Routing::RulePublisher.update(brand: brand, rule_id: rule_id, attributes: { then: {
        "queue" => "ip-financeiro-prioritaria", "priority" => 95, "sla_minutes" => 10, "first_attendant" => "ai"
      } })
      conversation = open_conversation(alto)

      route(conversation)

      expect(event(conversation, "conversation.routed")).to have_attributes(routing_rule_id: version.id, rule_version: 2)
      in_brand { expect(Conversation.find(conversation.id)).to have_attributes(priority: 95, sla_minutes: 10) }
    end

    it "fila da regra inexistente: conversation.unrouted, com a regra, e a conversa fica em triage" do
      rule = in_brand do
        RoutingRule.create!(name: "Fila sumida", position: 0, when: {}, then: { "queue" => "nao-existe", "priority" => 1 })
      end
      conversation = open_conversation(alto)

      result = route(conversation)

      expect(result.routed).to be(false)
      expect(result.conversation.state).to eq("triage")
      unrouted = event(conversation, "conversation.unrouted")
      expect(unrouted).to have_attributes(reason: "a fila da regra não existe na marca", routing_rule_id: rule.id, rule_version: 1)
      expect(event(conversation, "conversation.routed")).to be_nil
    end

    it "sem regra que case: conversation.unrouted sem regra" do
      in_brand do
        RoutingRule.current.each do |rule|
          RoutingRule.create!(rule_id: rule.rule_id, version: rule.version + 1, name: rule.name, position: rule.position,
                              when: rule["when"], then: rule["then"], active: false)
        end
      end
      conversation = open_conversation(alto)

      expect(route(conversation).routed).to be(false)
      expect(event(conversation, "conversation.unrouted")).to have_attributes(reason: "nenhuma regra casou", routing_rule_id: nil)
    end
  end

  describe "categorize" do
    def categorize(conversation, category)
      in_brand do
        described_class.call(conversation: Conversation.find(conversation.id), trigger: "categorize", category: category)
      end
    end

    it "a categoria vem do agente: with_ai volta a triage, solta o atendente e é roteada de novo" do
      conversation = open_conversation(alto)
      route(conversation)

      result = categorize(conversation, "app")

      expect(result.conversation).to have_attributes(state: "with_ai", category: "app", priority: 25,
                                                     queue_id: queue("ip-suporte-geral").id)
      classified = event(conversation, "conversation.classified")
      expect(classified).to have_attributes(actor_type: "ai", actor_id: ai_attendant.id)
      expect(classified.before).to eq("state" => "with_ai", "attendant_id" => ai_attendant.id, "category" => "repasse")
      expect(classified.after).to eq("state" => "triage", "attendant_id" => nil, "category" => "app")
      expect(event(conversation, "conversation.routed").payload.dig("payload", "trigger")).to eq("categorize")
    end

    it "a nova categoria pode levar à fila humana" do
      conversation = open_conversation(medio)
      route(conversation, text: "A maquininha não liga")

      result = categorize(conversation, "repasse")

      expect(result.conversation).to have_attributes(state: "awaiting_human", attendant_id: nil, category: "repasse")
    end

    it "exige a conversa em with_ai e a categoria" do
      conversation = open_conversation(alto)

      expect { categorize(conversation, "repasse") }.to raise_error(ArgumentError, "a conversa deve estar em with_ai")
      expect { categorize(conversation, nil) }.to raise_error(ArgumentError, "categoria não informada")
    end
  end

  it "recusa trigger desconhecido, inclusive escalate" do
    conversation = open_conversation(alto)

    expect { in_brand { described_class.call(conversation: conversation, trigger: "escalate") } }
      .to raise_error(ArgumentError, /trigger desconhecido/)
  end

  it "roda só dentro do Tenancy.with_brand da marca da conversa" do
    conversation = open_conversation(alto)

    expect { described_class.call(conversation: conversation, trigger: "intake", text: "oi") }.to raise_error(ArgumentError)
    expect do
      Tenancy.with_brand(jim) { described_class.call(conversation: conversation, trigger: "intake", text: "oi") }
    end.to raise_error(ArgumentError)
  end
end

require "rails_helper"

RSpec.describe Conversations::RoutingExplanation do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact_in_segment(brand, "alto_tpv") }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def explain(conversation)
    in_brand { described_class.for(Conversation.find(conversation.id)) }
  end

  def customer_writes(text)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"), text: text)
    ).first.conversation
  end

  it "mostra a regra, a versão, a fila, a prioridade, o SLA e a classificação do último roteamento" do
    conversation = customer_writes("Meu repasse de ontem não caiu")

    explanation = explain(conversation)

    rule = in_brand { RoutingRule.find_by!(name: "InfinitePay · Repasse · Alto volume", version: 1) }
    expect(explanation.routed).to include(
      rule_name: "InfinitePay · Repasse · Alto volume", rule_id: rule.rule_id, rule_version: 1,
      queue: "ip-financeiro-prioritaria", priority: 90, sla_minutes: 15, first_attendant: "ai", overflow: false,
      trigger: "intake"
    )
    expect(explanation.routed[:queue_chain].first).to include("queue" => "ip-financeiro-prioritaria", "capacity" => 20)
    expect(explanation.classified).to include(category: "repasse", trigger: "intake", actor_type: "system")
    expect(explanation.classified[:classifier_version]).to be_present
    expect(explanation.classified[:matches]["category"]).to be_present
    expect(explanation.escalated).to be_nil
  end

  it "mostra a escalação, com a fila de origem e a de destino" do
    conversation = customer_writes("Meu repasse de ontem não caiu")
    in_brand do
      Conversations::Escalate.call(conversation: Conversation.lock.find(conversation.id), reason: "pedido",
                                   summary: "Lojista pede analista", context: {}, actor_type: "system")
    end

    expect(explain(conversation).escalated).to include(
      from_queue: "ip-financeiro-prioritaria", to_queue: "ip-financeiro", moved: true, reason: "pedido",
      actor_type: "system"
    )
  end

  it "usa o último roteamento quando a conversa foi roteada mais de uma vez" do
    conversation = customer_writes("Meu repasse de ontem não caiu")
    in_brand do
      Routing::Route.call(conversation: Conversation.find(conversation.id), trigger: "categorize", category: "app")
    end

    explanation = explain(conversation)

    expect(explanation.routed).to include(trigger: "categorize", queue: "ip-suporte-geral", rule_name: "InfinitePay · App")
    expect(explanation.classified).to include(trigger: "categorize", category: "app", actor_type: "ai")
  end
end

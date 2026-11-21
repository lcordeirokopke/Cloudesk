require "rails_helper"

# Critério de pronto do admin: a edição de regra ou de fila vale na próxima conversa, sem deploy,
# e aparece na auditoria. O cache de teste é :null_store; aqui as regras compiladas ficam em um
# cache em memória, como no Solid Cache de desenvolvimento e produção.
RSpec.describe "Admin: a edição vale na próxima conversa", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
    admin_sign_in(brand)
  end

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def rule(name)
    in_brand { RoutingRule.latest_versions.find_by!(name: name) }
  end

  def queue(name)
    in_brand { Routing::Queue.find_by!(name: name) }
  end

  # Mensagem de WhatsApp de um lojista das seeds, pelo caminho único de entrada.
  def send_message(contact, text)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"), text: text)
    ).first.conversation
  end

  def routed_event(conversation)
    in_brand { AuditEvent.where(conversation_id: conversation.id, action: "conversation.routed").sole }
  end

  it "a regra editada no admin vale na próxima mensagem e aparece na tela e na auditoria" do
    target = rule("InfinitePay · Repasse")
    first = send_message(seed_contact_in_segment(brand, "baixo_tpv", 0), "Meu repasse não caiu")
    expect(routed_event(first).payload.dig("payload", "rule")).to include("version" => 1)
    expect(cache.exist?(Tenancy.with_brand(brand) { Routing::CompiledRules.cache_key(brand) })).to be(true)

    patch "/admin/rules/#{target.rule_id}", headers: admin_headers, params: {
      rule: { name: target.name, position: target.position.to_s, when: { category: [ "repasse" ] },
              then: { queue: "ip-urgente", priority: "77", sla_minutes: "60", first_attendant: "human" } },
      expected_version: 1
    }
    expect(response).to redirect_to("/admin/rules/#{target.rule_id}")

    second = send_message(seed_contact_in_segment(brand, "baixo_tpv", 1), "Meu repasse não caiu")
    payload = routed_event(second).payload.fetch("payload")
    expect(payload["rule"]).to include("rule_id" => target.rule_id, "version" => 2)
    expect(payload).to include("queue" => "ip-urgente", "priority" => 77)
    expect(routed_event(second)).to have_attributes(rule_version: 2)

    get "/admin/rules/#{target.rule_id}", headers: admin_headers
    expect(response.body).to include("Versão 2", "operator-a", "ip-urgente", "77")
    published = in_brand { AuditEvent.where(action: "routing_rule.published", routing_rule_id: rule(target.name).id).sole }
    expect(published.payload.dig("payload", "diff")).to eq(
      "then" => {
        "before" => { "queue" => "ip-financeiro", "priority" => 50, "sla_minutes" => 60, "first_attendant" => "human" },
        "after" => { "queue" => "ip-urgente", "priority" => 77, "sla_minutes" => 60, "first_attendant" => "human" }
      }
    )
    expect(published.payload.dig("payload", "operator_name")).to eq("operator-a")
  end

  it "a capacidade reduzida no admin vale no próximo roteamento: a fila cheia transborda" do
    priority_queue = queue("ip-financeiro-prioritaria")
    first = send_message(seed_contact_in_segment(brand, "alto_tpv", 0), "Meu repasse não caiu")
    expect(first.queue_id).to eq(priority_queue.id)

    get "/admin/queues/#{priority_queue.id}/edit", headers: admin_headers
    version = response.body[/name="expected_updated_at"[^>]*value="([^"]+)"/, 1]
    patch "/admin/queues/#{priority_queue.id}", headers: admin_headers,
                                                params: { queue: { capacity: "1" }, expected_updated_at: version }
    expect(response).to have_http_status(:see_other)

    second = send_message(seed_contact_in_segment(brand, "alto_tpv", 1), "Meu repasse não caiu")
    expect(second.queue_id).to eq(queue("ip-financeiro").id)
    expect(routed_event(second).payload.dig("payload", "overflow")).to be(true)
  end
end

require "rails_helper"

RSpec.describe "API de ações do agente", type: :request do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:path) { "/api/v1/agent/actions" }

  def customer_writes(text = "Minha maquininha não liga")
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"), text: text)
    ).first.conversation
  end

  def post_action(action, secret: agent_actions_secret, now: Time.now,
                  idempotency_key: Contract::IdempotencyKey.for_action(action), headers: {})
    body = action.is_a?(String) ? action : action.to_json
    signed = agent_signed_headers(secret: secret, method: "POST", path: path, body: body, now: now)
    signed[Contract::IdempotencyKey::HEADER] = idempotency_key if idempotency_key
    post path, params: body, headers: signed.merge("Content-Type" => "application/json").merge(headers)
  end

  def expect_contract(status)
    expect(response).to have_http_status(status)
    expect(Contract::Schemas.errors("action-response", response.parsed_body)).to eq([])
  end

  it "aceita a ação com 200 e repete o mesmo corpo na repetição da chave" do
    action = agent_action(customer_writes)

    post_action(action)
    expect_contract(:ok)
    first = response.parsed_body

    post_action(action)
    expect_contract(:ok)
    expect(response.parsed_body).to eq(first)
    expect(first).to include("status" => "accepted", "type" => "reply", "message_sequence" => 2)
  end

  it "grava no evento da ação o trace do header traceparent" do
    conversation = customer_writes
    traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    post_action(agent_action(conversation), headers: { "traceparent" => traceparent })

    event = audit_events_of(brand, conversation.id).find { |audit_event| audit_event.action == "agent.reply" }
    expect(event.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
  end

  it "responde 409 stale à ação desatualizada" do
    conversation = customer_writes
    action = agent_action(conversation)
    customer_writes("Ainda não liga")

    post_action(action)

    expect_contract(:conflict)
    expect(response.parsed_body).to include("status" => "stale", "last_customer_sequence" => 2)
  end

  it "responde 409 rejected à ação com a conversa fora de with_ai" do
    conversation = customer_writes
    post_action(agent_action(conversation, example: "resolve"))

    post_action(agent_action(conversation))

    expect_contract(:conflict)
    expect(response.parsed_body).to include("status" => "rejected", "state" => "resolved")
  end

  it "recusa a assinatura inválida, a assinatura com o segredo do contexto e o timestamp vencido com 401" do
    action = agent_action(customer_writes)

    post_action(action, secret: "outro-segredo")
    expect_contract(:unauthorized)
    expect(response.parsed_body["error"]).to eq("invalid_signature")

    post_action(action, secret: agent_context_secret)
    expect(response.parsed_body["error"]).to eq("invalid_signature")

    post_action(action, now: Time.now - 301)
    expect_contract(:unauthorized)
    expect(response.parsed_body["error"]).to eq("expired_timestamp")
  end

  it "recusa a chamada sem Idempotency-Key com 400" do
    post_action(agent_action(customer_writes), idempotency_key: nil)

    expect_contract(:bad_request)
    expect(response.parsed_body["error"]).to eq("missing_idempotency_key")
  end

  it "recusa o corpo inválido com 422" do
    # Só ASCII: o Rails grava o corpo inválido no log como texto binário, e o Logger, depois de girar o
    # test.log (100 MB), recusa binário fora do ASCII ("log writing failed").
    post_action("texto sem JSON", idempotency_key: "x:reply")
    expect_contract(:unprocessable_content)
    expect(response.parsed_body["error"]).to eq("invalid_payload")

    action = agent_action(customer_writes)
    post_action(action, idempotency_key: "#{action['inbound_event_id']}:escalate")
    expect_contract(:unprocessable_content)
  end

  it "responde 404 para marca inexistente e conversa de outra marca" do
    action = agent_action(customer_writes)

    post_action(action.merge("brand" => "outra"))
    expect_contract(:not_found)

    post_action(action.merge("brand" => "jim"))
    expect_contract(:not_found)
    expect(response.parsed_body["error"]).to eq("not_found")
  end
end

require "rails_helper"

RSpec.describe "Painel do analista: linha do tempo da mensagem", type: :request do
  let(:brand) { infinitepay }
  let(:browser) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }
  let(:authorized) { browser.merge("Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("analyst", "senha-de-teste")) }
  let(:analyst) { Tenancy.with_brand(brand) { Attendant.where(kind: "human", team: Team.find_by!(name: "Financeiro")).order(:name).first } }

  around do |example|
    previous = ENV.values_at("PANEL_USER", "PANEL_PASSWORD")
    ENV["PANEL_USER"] = "analyst"
    ENV["PANEL_PASSWORD"] = "senha-de-teste"
    example.run
  ensure
    ENV["PANEL_USER"], ENV["PANEL_PASSWORD"] = previous
  end

  before { stub_request(:post, %r{\Ahttp://whatsapp\.test/}).to_return(status: 200, body: "{}") }

  after { Current.reset }

  def sign_in(as = analyst, slug = "infinitepay")
    post "/panel/session", params: { analyst: "#{slug}:#{as.id}" }, headers: authorized
  end

  # Mensagem do lojista com a resposta da IA aceita e entregue. Devolve o resultado do Intake e a
  # resposta.
  def answered_message
    Current.traceparent = TraceContext.generate
    received = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(seed_contact(brand), "whatsapp"),
                      text: "Minha maquininha não liga")
    ).first
    action = agent_action(received.conversation, example: "reply")
    Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
    reply = Tenancy.with_brand(brand) { Message.where(conversation_id: received.conversation.id, author: "ai").sole }
    job = jobs_of(Channels::DeliveryJob).order(:id).to_a.reverse.find { |item| job_arguments(item)["message_id"] == reply.id }
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
    Current.reset
    [ received, reply ]
  end

  def timeline_path(conversation_id, message_id)
    "/panel/conversations/#{conversation_id}/messages/#{message_id}/timeline"
  end

  it "mostra os saltos e os eventos do trace da mensagem do lojista" do
    received, _reply = answered_message
    sign_in

    get timeline_path(received.conversation.id, received.message.id), headers: authorized

    expect(response).to have_http_status(:ok)
    body = response.body
    [ "Canal → Core", "Core → Broker", "Kafka", "Agente consumiu", "Ferramenta consultar_repasse", "Agente publicou",
      "Broker → Core", "Cliente" ].each { |label| expect(body).to include(CGI.escapeHTML(label)) }
    trace_id = Tenancy.with_brand(brand) { AuditEvent.find_by!(action: "message.created", target_id: received.message.id).trace_id }
    expect(body).to include(trace_id, "agent.reply", "message.delivered", "terminou em")
  end

  it "liga a mensagem do lojista à linha do tempo na tela da conversa" do
    received, reply = answered_message
    sign_in

    get "/panel/conversations/#{received.conversation.id}", headers: authorized

    expect(response.body).to include(timeline_path(received.conversation.id, received.message.id))
    expect(response.body).not_to include(timeline_path(received.conversation.id, reply.id))
  end

  it "responde 404 para mensagem do atendente" do
    received, reply = answered_message
    sign_in

    get timeline_path(received.conversation.id, reply.id), headers: authorized

    expect(response).to have_http_status(:not_found)
  end

  it "responde 404 para mensagem de outra conversa" do
    received, _reply = answered_message
    other = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(seed_contact(brand, 1), "whatsapp"),
                      text: "Outra conversa")
    ).first
    sign_in

    get timeline_path(other.conversation.id, received.message.id), headers: authorized

    expect(response).to have_http_status(:not_found)
  end

  it "responde 404 para conversa de outra marca" do
    received, _reply = answered_message
    jim_analyst = Tenancy.with_brand(jim) { Attendant.where(kind: "human", team: Team.find_by!(name: "Finance")).first }
    sign_in(jim_analyst, "jim")

    get timeline_path(received.conversation.id, received.message.id), headers: authorized

    expect(response).to have_http_status(:not_found)
  end

  it "exige basic auth" do
    received, _reply = answered_message

    get timeline_path(received.conversation.id, received.message.id), headers: browser

    expect(response).to have_http_status(:unauthorized)
  end

  it "exige o analista na sessão" do
    received, _reply = answered_message

    get timeline_path(received.conversation.id, received.message.id), headers: authorized

    expect(response).to redirect_to("/panel")
  end
end

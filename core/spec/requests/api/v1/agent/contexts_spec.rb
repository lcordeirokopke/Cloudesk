require "rails_helper"

RSpec.describe "Contexto da conversa para o agente", type: :request do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:conversation) do
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"),
                      text: "Minha maquininha não liga")
    ).first.conversation
  end

  def path_for(brand_slug, conversation_id, query: nil)
    [ "/api/v1/agent/brands/#{brand_slug}/conversations/#{conversation_id}/context", query ].compact.join("?")
  end

  def get_signed(path, secret: agent_context_secret, now: Time.now, signed_path: path)
    get path, headers: agent_signed_headers(secret: secret, method: "GET", path: signed_path, now: now)
  end

  it "a context_url do webhook é o caminho do endpoint" do
    expect(Contract::MessageCreated.context_url("infinitepay", conversation.id)).to eq(path_for("infinitepay", conversation.id))
  end

  it "devolve o contexto assinado com AGENT_CONTEXT_SECRET, conforme o schema context" do
    get_signed(path_for("infinitepay", conversation.id))

    expect(response).to have_http_status(:ok)
    expect(Contract::Schemas.errors("context", response.parsed_body)).to eq([])
    expect(response.parsed_body.dig("conversation", "id")).to eq(conversation.id)
    expect(response.parsed_body.fetch("messages").size).to eq(1)
  end

  it "assina o caminho com a query string" do
    path = path_for("infinitepay", conversation.id, query: "limit=50")

    get_signed(path)
    expect(response).to have_http_status(:ok)

    get_signed(path, signed_path: path_for("infinitepay", conversation.id))
    expect(response).to have_http_status(:unauthorized)
  end

  it "recusa a assinatura com o segredo das ações" do
    get_signed(path_for("infinitepay", conversation.id), secret: agent_actions_secret)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to include("status" => "error", "error" => "invalid_signature")
  end

  it "recusa o timestamp vencido" do
    get_signed(path_for("infinitepay", conversation.id), now: Time.now - 301)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to include("error" => "expired_timestamp")
    expect(Contract::Schemas.errors("action-response", response.parsed_body)).to eq([])
  end

  it "a marca do caminho entra na assinatura" do
    get_signed(path_for("jim", conversation.id), signed_path: path_for("infinitepay", conversation.id))

    expect(response).to have_http_status(:unauthorized)
  end

  it "responde 404 para a conversa de outra marca, marca inexistente e id que não é UUID" do
    [ path_for("jim", conversation.id), path_for("outra", conversation.id), path_for("infinitepay", "abc") ].each do |path|
      get_signed(path)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to include("status" => "error", "error" => "not_found")
    end
  end
end

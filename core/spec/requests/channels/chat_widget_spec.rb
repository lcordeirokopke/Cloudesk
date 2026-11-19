require "rails_helper"

RSpec.describe "Widget de chat", type: :request do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:app_user_id) { identity_of(contact, "chat") }
  let(:browser) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }

  def sign_in
    post "/chat/infinitepay/session", params: { app_user_id: app_user_id }, headers: browser
  end

  it "lista os lojistas da marca com identidade de chat" do
    get "/chat/infinitepay", headers: browser

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(app_user_id, CGI.escapeHTML(contact.name))
  end

  it "grava o lojista escolhido na sessão e abre a conversa" do
    sign_in

    expect(response).to redirect_to("/chat/infinitepay/conversation")
    get "/chat/infinitepay/conversation", headers: browser
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("turbo-cable-stream-source", CGI.escapeHTML(contact.name))
  end

  it "recusa lojista sem identidade de chat na marca" do
    post "/chat/infinitepay/session", params: { app_user_id: "app-inexistente" }, headers: browser

    expect(response).to redirect_to("/chat/infinitepay")
  end

  it "sem sessão, a conversa volta para a escolha do lojista" do
    get "/chat/infinitepay/conversation", headers: browser

    expect(response).to redirect_to("/chat/infinitepay")
  end

  it "envia a mensagem pelo formulário e mostra o histórico com o canal de cada mensagem" do
    sign_in
    Conversations::Intake.call(inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"),
                                               text: "Escrevi antes pelo WhatsApp"))

    post "/chat/infinitepay/messages", params: { text: "Agora pelo chat", client_message_id: "widget-1" }, headers: browser

    expect(response).to have_http_status(:see_other)
    Tenancy.with_brand(brand) do
      expect(Message.find_by!(channel: "chat", external_id: "widget-1").body).to eq("Agora pelo chat")
    end

    follow_redirect!(headers: browser)
    expect(response.body).to include("Escrevi antes pelo WhatsApp", "Agora pelo chat", "customer · whatsapp", "customer · chat")
  end
end

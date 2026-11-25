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

  describe "limite de taxa" do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(store) }

    around { |example| travel_to(Time.zone.parse("2026-11-23 14:00:07")) { example.run } }

    def send_message(index, text: "Mensagem #{index}")
      post "/chat/infinitepay/messages", params: { text: text, client_message_id: "widget-limite-#{index}" }, headers: browser
    end

    def exceed_limit
      5.times { |index| send_message(index) }
    end

    def post_json
      path = "/channels/chat/messages"
      body = { brand: "infinitepay", app_user_id: app_user_id, client_message_id: "json-limite", text: "Pela entrada JSON" }.to_json
      headers = Contract::Signature.headers(
        secret: ENV.fetch("CHAT_SIGNING_SECRET"), method: "POST", path: path, body: body, now: Time.now
      )
      post path, params: body, headers: headers.merge("Content-Type" => "application/json")
    end

    it "dentro do limite, grava as mensagens e redireciona com 303" do
      sign_in

      5.times do |index|
        send_message(index)
        expect(response).to have_http_status(:see_other)
      end

      ids = Array.new(5) { |index| "widget-limite-#{index}" }
      expect(Tenancy.with_brand(brand) { Message.where(channel: "chat", external_id: ids).count }).to eq(5)
    end

    it "acima do limite, responde 429 com Retry-After, aviso e o texto no campo, sem gravar" do
      sign_in
      exceed_limit

      expect { send_message(5, text: "Sexta mensagem") }
        .not_to(change { [ Tenancy.with_brand(brand) { [ Message.count, AuditEvent.count ] }, SolidQueue::Job.count ] })

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("3")
      page = Nokogiri::HTML5(response.body)
      expect(page.at_css("p.chat__alert").text).to eq("Muitas mensagens em pouco tempo. Aguarde 3 s e envie de novo.")
      expect(page.at_css("input[name='text']")["value"]).to eq("Sexta mensagem")
      expect(page.at_css("input[name='client_message_id']")["value"]).to be_nil
      expect(response.body).to include("Mensagem 0", "Mensagem 4")
    end

    it "não leva o aviso nem o texto para a página seguinte" do
      sign_in
      exceed_limit
      send_message(5, text: "Sexta mensagem")

      get "/chat/infinitepay/conversation", headers: browser

      page = Nokogiri::HTML5(response.body)
      expect(page.at_css("p.chat__alert")).to be_nil
      expect(page.at_css("input[name='text']")["value"]).to be_nil
    end

    it "continua recusando o mesmo lojista em uma sessão nova" do
      sign_in
      exceed_limit

      reset!
      sign_in
      send_message(5)

      expect(response).to have_http_status(:too_many_requests)
    end

    it "depois da recusa, a entrada JSON da mesma marca responde 200" do
      sign_in
      6.times { |index| send_message(index) }
      expect(response).to have_http_status(:too_many_requests)

      post_json

      expect(response).to have_http_status(:ok)
    end

    it "não conta a mensagem vazia" do
      sign_in
      6.times { send_message(0, text: "   ") }
      expect(response).to redirect_to("/chat/infinitepay/conversation")

      send_message(1)

      expect(response).to have_http_status(:see_other)
      expect(store.read(Channels::RateLimit.widget_contact_key(brand, contact, Time.current.to_i)).to_i).to eq(1)
    end

    it "aceita de novo na janela seguinte" do
      sign_in
      6.times { |index| send_message(index) }
      expect(response).to have_http_status(:too_many_requests)

      travel_to(Time.zone.parse("2026-11-23 14:00:10"))
      send_message(6)

      expect(response).to have_http_status(:see_other)
    end

    it "devolve o texto com HTML escapado" do
      sign_in
      exceed_limit

      send_message(5, text: %("><script>alert(1)</script>))

      expect(response.body).not_to include("<script>alert(1)</script>")
      expect(Nokogiri::HTML5(response.body).at_css("input[name='text']")["value"]).to eq(%("><script>alert(1)</script>))
    end
  end
end

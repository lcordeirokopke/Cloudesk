require "rails_helper"

RSpec.describe "Painel do analista: fila, conversa e ações", type: :request do
  let(:brand) { infinitepay }
  let(:browser) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }
  let(:authorized) { browser.merge("Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("analyst", "senha-de-teste")) }

  around do |example|
    previous = ENV.values_at("PANEL_USER", "PANEL_PASSWORD")
    ENV["PANEL_USER"] = "analyst"
    ENV["PANEL_PASSWORD"] = "senha-de-teste"
    example.run
  ensure
    ENV["PANEL_USER"], ENV["PANEL_PASSWORD"] = previous
  end

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def analysts(team_name)
    in_brand { Attendant.where(kind: "human", team: Team.find_by!(name: team_name)).order(:name).to_a }
  end

  let(:analyst) { analysts("Financeiro").first }
  let(:contact) { seed_contact_in_segment(brand, "alto_tpv") }

  def sign_in(as = analyst, slug = "infinitepay")
    post "/panel/session", params: { analyst: "#{slug}:#{as.id}" }, headers: authorized
  end

  # Repasse de lojista alto_tpv vai à fila prioritária da IA; o escalate do agente leva à fila
  # ip-financeiro, da equipe Financeiro.
  def escalated_conversation(from: contact)
    conversation = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(from, "whatsapp"),
                      text: "Meu repasse de ontem não caiu")
    ).first.conversation
    Agents::ActionProcessor.call(action: agent_action(conversation, example: "escalate"),
                                 idempotency_key: Contract::IdempotencyKey.for_action(agent_action(conversation, example: "escalate")))
    in_brand { Conversation.find(conversation.id) }
  end

  def take_next
    post "/panel/assignments", headers: authorized
  end

  describe "fila de escalas" do
    it "mostra as conversas da equipe com motivo, resumo e SLA, e assina o stream da equipe" do
      conversation = escalated_conversation
      sign_in

      get "/panel/queue", headers: authorized

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(contact.name), "ip-financeiro", "repasse_nao_localizado",
                                       "turbo-cable-stream-source", "Pegar próximo")
      expect(response.body).to include("waiting_conversation_#{conversation.id}")
      expect(response.body).to include(Turbo::StreamsChannel.signed_stream_name(Conversations::PanelBroadcast.team_stream(analyst.team_id)))
    end

    it "não mostra conversas de outra equipe" do
      escalated_conversation
      sign_in(analysts("Suporte Técnico").first)

      get "/panel/queue", headers: authorized

      expect(response.body).not_to include(CGI.escapeHTML(contact.name))
    end
  end

  describe "pegar próximo" do
    it "atribui o caso ao analista e abre a conversa" do
      conversation = escalated_conversation
      sign_in

      take_next

      expect(response).to redirect_to("/panel/conversations/#{conversation.id}")
      expect(in_brand { Conversation.find(conversation.id) }).to have_attributes(state: "with_human", attendant_id: analyst.id)
      get "/panel/queue", headers: authorized
      expect(response.body).to include("mine_conversation_#{conversation.id}")
    end

    it "sem caso, volta à fila com aviso" do
      sign_in

      take_next

      expect(response).to redirect_to("/panel/queue")
      follow_redirect!(headers: authorized)
      expect(response.body).to include("Nenhum caso disponível")
    end
  end

  describe "tela da conversa" do
    it "mostra o histórico, o cartão do handoff, a explicação do roteamento e da escalação" do
      conversation = escalated_conversation
      sign_in

      get "/panel/conversations/#{conversation.id}", headers: authorized

      body = response.body
      expect(response).to have_http_status(:ok)
      expect(body).to include("Meu repasse de ontem não caiu")
      expect(body).to include("Briefing do handoff", CGI.escapeHTML("Lojista relata repasse de ontem não recebido"),
                              "consultar_repasse", "negative", "35%",
                              CGI.escapeHTML("Verificar o repasse no sistema financeiro e informar o prazo ao lojista"))
      expect(body).to include("Por que caiu aqui?", CGI.escapeHTML("InfinitePay · Repasse · Alto volume"), "versão 1",
                              "ip-financeiro-prioritaria", "ip-financeiro")
      expect(body).to include(Turbo::StreamsChannel.signed_stream_name(Conversations::PanelBroadcast.conversation_stream(conversation.id)))
      expect(body).not_to include("Resolver")
    end

    it "mostra as conversas anteriores do lojista em todos os canais e a memória" do
      previous = Conversations::Intake.call(
        inbound_message(brand: brand, channel: "email", identity: identity_of(contact, "email"), text: "Pedido antigo por e-mail")
      ).first.conversation
      resolve_conversation(brand, previous.id, 2.days.ago)
      in_brand { CustomerMemory.create!(contact_id: contact.id, summary: "Lojista já perguntou sobre repasse") }
      conversation = escalated_conversation
      sign_in

      get "/panel/conversations/#{conversation.id}", headers: authorized

      expect(response.body).to include("previous_conversation_#{previous.id}", "Pedido antigo por e-mail",
                                       "Memória do lojista", CGI.escapeHTML("Lojista já perguntou sobre repasse"))
    end

    it "conversa de outra marca não existe para o analista" do
      conversation = escalated_conversation
      jim_analyst = Tenancy.with_brand(jim) { Attendant.where(kind: "human", team: Team.find_by!(name: "Finance")).first }
      sign_in(jim_analyst, "jim")

      get "/panel/conversations/#{conversation.id}", headers: authorized

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ações do analista" do
    it "responde pelo canal de origem, resolve e avalia o briefing" do
      conversation = escalated_conversation
      sign_in
      take_next

      post "/panel/conversations/#{conversation.id}/replies", params: { text: "Vou verificar seu repasse." }, headers: authorized
      expect(response).to redirect_to("/panel/conversations/#{conversation.id}")
      reply = in_brand { Message.where(conversation_id: conversation.id, author: "analyst").sole }
      expect(reply).to have_attributes(channel: "whatsapp", attendant_id: analyst.id, body: "Vou verificar seu repasse.")

      post "/panel/conversations/#{conversation.id}/resolution", headers: authorized
      expect(in_brand { Conversation.find(conversation.id).state }).to eq("resolved")

      handoff = in_brand { Handoff.find_by!(conversation_id: conversation.id) }
      post "/panel/handoffs/#{handoff.id}/rating", params: { rating: "useful" }, headers: authorized
      expect(response).to redirect_to("/panel/conversations/#{conversation.id}")
      expect(in_brand { Handoff.find(handoff.id) }).to have_attributes(rating: "useful", rated_by_id: analyst.id)

      follow_redirect!(headers: authorized)
      expect(response.body).to include("Briefing avaliado como <strong>útil</strong>", "depois da escalação")
    end

    it "com a conversa atribuída, mostra o formulário, resolver e a avaliação" do
      conversation = escalated_conversation
      sign_in
      take_next

      get "/panel/conversations/#{conversation.id}", headers: authorized

      expect(response.body).to include("Resolver", "Enviar", "O briefing foi útil?", "ainda sem resposta")
    end

    it "outro analista não responde a conversa e recebe aviso" do
      conversation = escalated_conversation
      sign_in
      take_next
      sign_in(analysts("Financeiro").second)

      post "/panel/conversations/#{conversation.id}/replies", params: { text: "Oi" }, headers: authorized

      expect(response).to redirect_to("/panel/conversations/#{conversation.id}")
      follow_redirect!(headers: authorized)
      expect(response.body).to include("a conversa não está com este analista")
      in_brand { expect(Message.where(conversation_id: conversation.id, author: "analyst")).to be_empty }
    end
  end
end

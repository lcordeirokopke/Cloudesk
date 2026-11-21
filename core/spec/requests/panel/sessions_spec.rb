require "rails_helper"

RSpec.describe "Painel do analista: acesso e login simulado", type: :request do
  let(:user) { "analyst" }
  let(:password) { "panel-password-de-teste" }
  let(:browser) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }
  let(:authorized) { browser.merge("Authorization" => basic_auth(user, password)) }

  # As credenciais são lidas do ambiente a cada requisição; o teste usa valores próprios.
  around do |example|
    previous = ENV.values_at("PANEL_USER", "PANEL_PASSWORD")
    ENV["PANEL_USER"] = user
    ENV["PANEL_PASSWORD"] = password
    example.run
  ensure
    ENV["PANEL_USER"], ENV["PANEL_PASSWORD"] = previous
  end

  def basic_auth(user, password)
    ActionController::HttpAuthentication::Basic.encode_credentials(user, password)
  end

  def analyst_of(brand, team_name)
    Tenancy.with_brand(brand) { Attendant.where(kind: "human", team: Team.find_by!(name: team_name)).order(:name).first }
  end

  describe "basic auth" do
    it "responde 401 sem credencial" do
      get "/panel", headers: browser

      expect(response).to have_http_status(:unauthorized)
    end

    it "responde 401 com senha errada" do
      get "/panel", headers: browser.merge("Authorization" => basic_auth(user, "errada"))

      expect(response).to have_http_status(:unauthorized)
    end

    it "responde 401 com a senha do ambiente vazia" do
      ENV["PANEL_PASSWORD"] = ""

      get "/panel", headers: browser.merge("Authorization" => basic_auth(user, ""))

      expect(response).to have_http_status(:unauthorized)
    end

    it "protege também as páginas internas" do
      get "/panel/queue", headers: browser

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "login simulado" do
    it "lista as marcas e os analistas humanos com equipe" do
      get "/panel", headers: authorized

      expect(response).to have_http_status(:ok)
      ip_analyst = analyst_of(infinitepay, "Financeiro")
      jim_analyst = analyst_of(jim, "Finance")
      expect(response.body).to include("infinitepay:#{ip_analyst.id}", "jim:#{jim_analyst.id}",
                                       CGI.escapeHTML(ip_analyst.name))
      ai = Tenancy.with_brand(infinitepay) { Attendant.first_ai }
      expect(response.body).not_to include(ai.id)
    end

    it "grava a marca e o analista na sessão e abre a fila da equipe" do
      analyst = analyst_of(infinitepay, "Financeiro")

      post "/panel/session", params: { analyst: "infinitepay:#{analyst.id}" }, headers: authorized

      expect(response).to redirect_to("/panel/queue")
      get "/panel/queue", headers: authorized
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Fila de escalas · Financeiro", CGI.escapeHTML(analyst.name))
    end

    it "recusa analista de outra marca com o slug trocado" do
      jim_analyst = analyst_of(jim, "Finance")

      post "/panel/session", params: { analyst: "infinitepay:#{jim_analyst.id}" }, headers: authorized

      expect(response).to redirect_to("/panel")
      follow_redirect!(headers: authorized)
      expect(response.body).to include("Analista não encontrado")
    end

    it "sem sessão, as páginas internas voltam à escolha do analista" do
      get "/panel/queue", headers: authorized

      expect(response).to redirect_to("/panel")
    end

    it "trocar analista limpa a sessão" do
      analyst = analyst_of(infinitepay, "Financeiro")
      post "/panel/session", params: { analyst: "infinitepay:#{analyst.id}" }, headers: authorized

      delete "/panel/session", headers: authorized
      get "/panel/queue", headers: authorized

      expect(response).to redirect_to("/panel")
    end
  end
end

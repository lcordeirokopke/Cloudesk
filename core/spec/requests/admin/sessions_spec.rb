require "rails_helper"

RSpec.describe "Admin: acesso e escolha da marca", type: :request do
  include_context "admin"

  let(:browser) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }

  describe "basic auth" do
    it "responde 401 sem credencial" do
      get "/admin", headers: browser

      expect(response).to have_http_status(:unauthorized)
    end

    it "responde 401 com senha errada" do
      get "/admin", headers: admin_headers(AdminHelpers::ADMIN_USER, "errada")

      expect(response).to have_http_status(:unauthorized)
    end

    it "responde 401 com ADMIN_USER ou ADMIN_PASSWORD vazios, mesmo com credencial vazia enviada" do
      ENV["ADMIN_PASSWORD"] = ""
      get "/admin", headers: admin_headers(AdminHelpers::ADMIN_USER, "")
      expect(response).to have_http_status(:unauthorized)

      ENV["ADMIN_PASSWORD"] = AdminHelpers::ADMIN_PASSWORD
      ENV["ADMIN_USER"] = ""
      get "/admin", headers: admin_headers("", AdminHelpers::ADMIN_PASSWORD)
      expect(response).to have_http_status(:unauthorized)
    end

    it "protege também as páginas internas e as gravações" do
      get "/admin/rules", headers: browser
      expect(response).to have_http_status(:unauthorized)

      post "/admin/queues", params: { queue: { name: "x" } }, headers: browser
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "marca" do
    it "lista as marcas e grava a escolhida na sessão" do
      get "/admin", headers: admin_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("InfinitePay", "JIM")

      admin_sign_in(jim)
      expect(response).to redirect_to("/admin/rules")
      get "/admin/rules", headers: admin_headers
      expect(response.body).to include("JIM · General", "operador operator-a")
      expect(response.body).not_to include("InfinitePay · Geral")
    end

    it "recusa marca inexistente" do
      post "/admin/session", params: { brand: "outra" }, headers: admin_headers

      expect(response).to redirect_to("/admin")
      follow_redirect!(headers: admin_headers)
      expect(response.body).to include("Marca não encontrada")
    end

    it "sem marca, as páginas internas voltam à escolha" do
      get "/admin/queues", headers: admin_headers

      expect(response).to redirect_to("/admin")
    end

    it "trocar marca limpa a sessão" do
      admin_sign_in(infinitepay)
      delete "/admin/session", headers: admin_headers
      get "/admin/rules", headers: admin_headers

      expect(response).to redirect_to("/admin")
    end
  end

  describe "sem exclusão" do
    it "não existe rota de DELETE para filas, equipes, atendentes e regras, e nada é apagado" do
      admin_sign_in(infinitepay)
      records = Tenancy.with_brand(infinitepay) do
        {
          "queues" => Routing::Queue.first!.id, "teams" => Team.first!.id, "attendants" => Attendant.first!.id,
          "rules" => RoutingRule.first!.rule_id
        }
      end
      counts = -> { Tenancy.with_brand(infinitepay) { [ Routing::Queue.count, Team.count, Attendant.count, RoutingRule.count ] } }
      before_counts = counts.call

      records.each do |resource, id|
        delete "/admin/#{resource}/#{id}", headers: admin_headers
        expect(response).to have_http_status(:not_found), resource
      rescue ActionController::RoutingError
        nil
      end
      expect(counts.call).to eq(before_counts)
    end
  end
end

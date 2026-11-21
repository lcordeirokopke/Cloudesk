require "rails_helper"

RSpec.describe "Admin: equipes", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }
  let(:hours_fields) { { hours_mode: "set", weekdays: [ "", "1", "2", "3" ], from: "09:00", to: "18:00", timezone: "America/Sao_Paulo" } }

  before { admin_sign_in(brand) }

  def team(name)
    Tenancy.with_brand(brand) { Team.find_by!(name: name) }
  end

  def form_version(target)
    get "/admin/teams/#{target.id}/edit", headers: admin_headers
    response.body[/name="expected_updated_at"[^>]*value="([^"]+)"/, 1]
  end

  it "lista as equipes com o horário" do
    get "/admin/teams", headers: admin_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Financeiro", "Suporte Técnico", "America/Sao_Paulo")
  end

  it "cria a equipe com horário pelos campos e mostra o histórico" do
    post "/admin/teams", headers: admin_headers, params: { team: { name: "Cobrança", skills: "repasse, taxas" }.merge(hours_fields) }

    created = team("Cobrança")
    expect(response).to redirect_to("/admin/teams/#{created.id}")
    expect(created.skills).to eq(%w[repasse taxas])
    expect(created.business_hours).to eq("weekdays" => [ 1, 2, 3 ], "from" => "09:00", "to" => "18:00",
                                         "timezone" => "America/Sao_Paulo")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("team.created", "operator-a")
  end

  it "cria a equipe sem horário" do
    post "/admin/teams", headers: admin_headers, params: { team: { name: "Plantão", skills: "", hours_mode: "none" } }

    expect(team("Plantão").business_hours).to eq({})
  end

  it "recusa horário vazio na equipe com regra hours, com 422 e a mensagem" do
    target = team("Suporte Técnico")

    patch "/admin/teams/#{target.id}", headers: admin_headers, params: {
      team: { name: "Suporte Técnico", skills: "maquininha, app", hours_mode: "none" }, expected_updated_at: form_version(target)
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("InfinitePay · Maquininha")
    expect(team("Suporte Técnico").business_hours).to be_present
  end

  it "edita o horário e mostra o diff" do
    target = team("Financeiro")

    patch "/admin/teams/#{target.id}", headers: admin_headers, params: {
      team: { name: "Financeiro", skills: "repasse, taxas, transacao" }.merge(hours_fields), expected_updated_at: form_version(target)
    }

    expect(response).to redirect_to("/admin/teams/#{target.id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("team.updated", "business_hours")
  end
end

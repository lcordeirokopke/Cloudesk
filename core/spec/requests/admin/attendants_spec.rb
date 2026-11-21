require "rails_helper"

RSpec.describe "Admin: atendentes", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }

  before { admin_sign_in(brand) }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def first_ai
    in_brand { Attendant.first_ai }
  end

  def analyst
    in_brand { Attendant.where(kind: "human").order(:name).first! }
  end

  it "lista a IA, só leitura, e os analistas" do
    get "/admin/attendants", headers: admin_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(CGI.escapeHTML(first_ai.name), "IA (só leitura)", CGI.escapeHTML(analyst.name))
  end

  it "cria analista; kind ai enviado é ignorado e o first_ai não muda" do
    ai_before = first_ai

    post "/admin/attendants", headers: admin_headers,
                              params: { attendant: { name: "Aaa Analista", kind: "ai", team_id: "", capacity: "4", skills: "pix" } }

    created = in_brand { Attendant.find_by!(name: "Aaa Analista") }
    expect(response).to redirect_to("/admin/attendants/#{created.id}")
    expect(created).to have_attributes(kind: "human", capacity: 4, team_id: nil, skills: %w[pix])
    expect(first_ai).to have_attributes(id: ai_before.id, name: ai_before.name)
  end

  it "edita o analista e mostra o histórico" do
    target = analyst
    get "/admin/attendants/#{target.id}/edit", headers: admin_headers
    version = response.body[/name="expected_updated_at"[^>]*value="([^"]+)"/, 1]

    patch "/admin/attendants/#{target.id}", headers: admin_headers, params: {
      attendant: { name: target.name, team_id: target.team_id, capacity: "9", skills: target.skills.join(", ") },
      expected_updated_at: version
    }

    expect(response).to redirect_to("/admin/attendants/#{target.id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("attendant.updated", "capacity")
  end

  it "o atendente IA é só leitura: edit redireciona e PATCH é recusado, sem mudar o first_ai" do
    ai = first_ai

    get "/admin/attendants/#{ai.id}", headers: admin_headers
    expect(response.body).to include("Só leitura")
    expect(response.body).not_to include("/admin/attendants/#{ai.id}/edit")

    get "/admin/attendants/#{ai.id}/edit", headers: admin_headers
    expect(response).to redirect_to("/admin/attendants/#{ai.id}")

    patch "/admin/attendants/#{ai.id}", headers: admin_headers, params: {
      attendant: { name: "Aaa IA", capacity: "1" }, expected_updated_at: Admin::Editor.version_of(ai)
    }
    expect(response).to redirect_to("/admin/attendants/#{ai.id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("o atendente IA não é editado pelo admin")
    expect(first_ai).to have_attributes(id: ai.id, name: ai.name, capacity: ai.capacity)
  end

  it "recusa capacidade inválida com 422" do
    post "/admin/attendants", headers: admin_headers, params: { attendant: { name: "X", capacity: "0" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("Capacity")
  end
end

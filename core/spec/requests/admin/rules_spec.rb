require "rails_helper"

RSpec.describe "Admin: regras", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }

  before { admin_sign_in(brand) }

  def rule(name)
    Tenancy.with_brand(brand) { RoutingRule.latest_versions.find_by!(name: name) }
  end

  def versions(rule_id)
    Tenancy.with_brand(brand) { RoutingRule.where(rule_id: rule_id).count }
  end

  def rule_params(rule, **changes)
    then_clause = rule["then"].transform_values(&:to_s)
    {
      rule: {
        name: rule.name, position: rule.position.to_s,
        when: rule["when"].except("brand").transform_values { |value| Array.wrap(value) },
        then: { "queue" => "", "priority" => "", "sla_minutes" => "", "first_attendant" => "" }.merge(then_clause)
      }.deep_merge(changes),
      expected_version: rule.version
    }
  end

  it "lista as regras na maior versão em ordem de avaliação, com fila, prioridade, versão e estado" do
    get "/admin/rules", headers: admin_headers

    expect(response).to have_http_status(:ok)
    body = response.body
    names = [ "InfinitePay · Urgente · Alto volume", "InfinitePay · Repasse", "InfinitePay · Geral" ].map { |name| CGI.escapeHTML(name) }
    expect(names.map { |name| body.index(name) }).to eq(names.map { |name| body.index(name) }.sort)
    expect(body).to include("ip-suporte-geral", "ativa")
  end

  it "cria a regra pelo formulário estruturado" do
    get "/admin/rules/new", headers: admin_headers
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("alto_tpv", "maquininha", "whatsapp", "pt-BR")

    post "/admin/rules", headers: admin_headers, params: {
      rule: { name: "Chat · Taxas", position: "5", when: { channel: [ "", "chat" ], category: [ "", "taxas" ], hours: "" },
              then: { queue: "ip-financeiro", priority: "40", sla_minutes: "", first_attendant: "" } }
    }

    created = rule("Chat · Taxas")
    expect(response).to redirect_to("/admin/rules/#{created.rule_id}")
    expect(created["when"]).to eq("brand" => "infinitepay", "channel" => "chat", "category" => "taxas")
    expect(created["then"]).to eq("queue" => "ip-financeiro", "priority" => 40)
  end

  it "edita a regra, publica a versão nova e mostra versões e diff" do
    target = rule("InfinitePay · Geral")

    patch "/admin/rules/#{target.rule_id}", headers: admin_headers, params: rule_params(target, then: { "priority" => "12" })

    expect(response).to redirect_to("/admin/rules/#{target.rule_id}")
    expect(rule("InfinitePay · Geral")).to have_attributes(version: 2)
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("Versão 2", "routing_rule.published", "operator-a", "versão 2")
  end

  it "definição inválida volta ao formulário com 422 e a mensagem" do
    target = rule("InfinitePay · Geral")

    patch "/admin/rules/#{target.rule_id}", headers: admin_headers, params: rule_params(target, then: { "queue" => "nenhuma" })

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("then.queue não existe na marca: nenhuma")
    expect(versions(target.rule_id)).to eq(1)
  end

  it "versão antiga volta ao formulário com aviso, sem versão nova" do
    target = rule("InfinitePay · Geral")
    patch "/admin/rules/#{target.rule_id}", headers: admin_headers, params: rule_params(target, then: { "priority" => "12" })

    patch "/admin/rules/#{target.rule_id}", headers: admin_headers, params: rule_params(target, then: { "priority" => "13" })

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("recarregue a página")
    expect(versions(target.rule_id)).to eq(2)
  end

  it "valor fora da lista aparece marcado; salvar sem mexer não grava e mudar outro campo o mantém" do
    vip = Routing::RulePublisher.create(
      brand: brand, attributes: { name: "VIP", position: 3, when: { brand: "infinitepay", segment: "vip" },
                                  then: { queue: "ip-urgente", priority: 99 } }
    )

    get "/admin/rules/#{vip.rule_id}/edit", headers: admin_headers
    expect(response.body).to match(/value="vip" checked="checked"/)
    expect(response.body).to include("fora da lista")

    patch "/admin/rules/#{vip.rule_id}", headers: admin_headers, params: rule_params(vip)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("A edição não muda a regra")

    patch "/admin/rules/#{vip.rule_id}", headers: admin_headers, params: rule_params(vip, position: "4")
    expect(rule("VIP")).to have_attributes(version: 2, position: 4)
    expect(rule("VIP")["when"]).to eq("brand" => "infinitepay", "segment" => "vip")
  end

  it "desativa e ativa a regra" do
    target = rule("InfinitePay · App")

    post "/admin/rules/#{target.rule_id}/deactivate", headers: admin_headers, params: { expected_version: 1 }
    expect(rule("InfinitePay · App")).to have_attributes(version: 2, active: false)

    post "/admin/rules/#{target.rule_id}/activate", headers: admin_headers, params: { expected_version: 2 }
    expect(rule("InfinitePay · App")).to have_attributes(version: 3, active: true)
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("Regra ativada")
  end

  it "desativar a regra genérica mostra a recusa e não grava versão nova" do
    target = rule("InfinitePay · Geral")

    post "/admin/rules/#{target.rule_id}/deactivate", headers: admin_headers, params: { expected_version: 1 }

    expect(response).to redirect_to("/admin/rules/#{target.rule_id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("A marca precisa manter uma regra genérica ativa")
    expect(versions(target.rule_id)).to eq(1)
  end

  it "regra de outra marca não existe" do
    jim_rule = Tenancy.with_brand(jim) { RoutingRule.latest_versions.find_by!(name: "JIM · General") }

    get "/admin/rules/#{jim_rule.rule_id}", headers: admin_headers
    expect(response).to have_http_status(:not_found)
    post "/admin/rules/#{jim_rule.rule_id}/deactivate", headers: admin_headers, params: { expected_version: 1 }
    expect(response).to have_http_status(:not_found)
  end
end

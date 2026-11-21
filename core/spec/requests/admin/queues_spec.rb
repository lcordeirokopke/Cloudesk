require "rails_helper"

RSpec.describe "Admin: filas", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }

  before { admin_sign_in(brand) }

  def queue(name, target = brand)
    Tenancy.with_brand(target) { Routing::Queue.find_by!(name: name) }
  end

  def team(name)
    Tenancy.with_brand(brand) { Team.find_by!(name: name) }
  end

  # updated_at levado pelo formulário de edição.
  def form_version(target)
    get "/admin/queues/#{target.id}/edit", headers: admin_headers
    response.body[/name="expected_updated_at"[^>]*value="([^"]+)"/, 1]
  end

  def queue_events(target)
    Tenancy.with_brand(brand) { AuditEvent.where(target_type: "Routing::Queue", target_id: target.id).order(:created_at).to_a }
  end

  it "lista as filas da marca" do
    get "/admin/queues", headers: admin_headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ip-financeiro-prioritaria", "ip-suporte-geral", "Suporte Técnico")
    expect(response.body).not_to include("jim-finance")
  end

  it "cria a fila pelo formulário e mostra o histórico" do
    get "/admin/queues/new", headers: admin_headers
    expect(response).to have_http_status(:ok)

    post "/admin/queues", headers: admin_headers, params: {
      queue: { name: "ip-cobranca", team_id: team("Financeiro").id, sla_minutes: "30", capacity: "10",
               first_attendant: "human", overflow_queue_id: "", escalation_queue_id: "" }
    }

    created = queue("ip-cobranca")
    expect(response).to redirect_to("/admin/queues/#{created.id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("Fila criada", "queue.created", "operator-a")
    expect(created).to have_attributes(sla_minutes: 30, capacity: 10, overflow_queue_id: nil)
  end

  it "edita a fila e mostra o diff no histórico" do
    target = queue("ip-maquininha")

    patch "/admin/queues/#{target.id}", headers: admin_headers,
                                        params: { queue: { capacity: "70" }, expected_updated_at: form_version(target) }

    expect(response).to redirect_to("/admin/queues/#{target.id}")
    follow_redirect!(headers: admin_headers)
    expect(response.body).to include("queue.updated", "capacity", "60", "70")
  end

  it "recusas voltam ao formulário com 422 e a mensagem" do
    target = queue("ip-suporte-geral")

    patch "/admin/queues/#{target.id}", headers: admin_headers,
                                        params: { queue: { name: "ip-suporte" }, expected_updated_at: form_version(target) }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("InfinitePay · Geral", "mude as regras antes de renomear")

    post "/admin/queues", headers: admin_headers, params: { queue: { name: "", sla_minutes: "0", capacity: "1", first_attendant: "ai" } }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "updated_at antigo volta ao formulário com aviso para recarregar" do
    target = queue("ip-maquininha")
    old_version = form_version(target)
    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "70" }, expected_updated_at: old_version }

    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "80" }, expected_updated_at: old_version }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("recarregue a página")
    expect(queue("ip-maquininha").capacity).to eq(70)
  end

  it "duas edições seguidas, cada uma com o updated_at do formulário recarregado, passam" do
    target = queue("ip-maquininha")

    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "70" }, expected_updated_at: form_version(target) }
    expect(response).to have_http_status(:see_other)
    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "71" }, expected_updated_at: form_version(target) }
    expect(response).to have_http_status(:see_other)

    expect(queue("ip-maquininha").capacity).to eq(71)
  end

  it "o operator_name é o usuário do basic auth de cada edição, com actor_id null" do
    target = queue("ip-maquininha")
    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "70" }, expected_updated_at: form_version(target) }

    ENV["ADMIN_USER"] = "operator-b"
    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "71" }, expected_updated_at: form_version(target) }

    events = queue_events(target)
    expect(events.map { |event| event.payload.dig("payload", "operator_name") }).to eq(%w[operator-a operator-b])
    expect(events.map(&:actor_id)).to eq([ nil, nil ])
    expect(events.map(&:actor_type)).to eq(%w[operator operator])
  end

  it "com a marca jim na sessão, a fila da infinitepay não existe e nada muda" do
    target = queue("ip-maquininha")
    version = form_version(target)
    admin_sign_in(jim)

    get "/admin/queues/#{target.id}", headers: admin_headers
    expect(response).to have_http_status(:not_found)
    get "/admin/queues/#{target.id}/edit", headers: admin_headers
    expect(response).to have_http_status(:not_found)
    patch "/admin/queues/#{target.id}", headers: admin_headers, params: { queue: { capacity: "70" }, expected_updated_at: version }
    expect(response).to have_http_status(:not_found)

    expect(queue("ip-maquininha").capacity).to eq(60)
    expect(queue_events(target)).to be_empty
  end
end

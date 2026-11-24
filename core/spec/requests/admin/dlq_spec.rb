require "rails_helper"

RSpec.describe "Admin: DLQ", type: :request do
  include_context "admin"

  let(:brand) { infinitepay }
  let(:conversation) { Tenancy.with_brand(brand) { Conversation.create!(contact: Contact.first!, channel: "whatsapp") } }

  it "exige o basic auth" do
    get "/admin/dlq", headers: { "User-Agent" => ChannelHelpers::MODERN_BROWSER }

    expect(response).to have_http_status(:unauthorized)
  end

  it "sem marca na sessão, volta à escolha da marca" do
    get "/admin/dlq", headers: admin_headers

    expect(response).to redirect_to("/admin")
  end

  context "com a marca escolhida" do
    before { admin_sign_in(brand) }

    it "lista as mensagens com os reprocessamentos anteriores e o bloqueio com o motivo" do
      stub_dlq_list(brand, [
        dlq_listed_message(partition: 1, offset: 7, key: conversation.id),
        dlq_listed_message(partition: 0, offset: 2, key: conversation.id, reason: "invalid_message", status: nil)
      ])
      stub_dlq_reprocess(1, 7)
      Admin::DlqReprocessor.call(brand: brand, partition: 1, offset: 7, operator_name: "operator-b")

      get "/admin/dlq", headers: admin_headers

      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      rows = page.css("tbody tr")
      expect(rows.size).to eq(2)
      expect(rows[0].text).to include("1@7", "core_rejected", "422", conversation.id, "operator-b", "2@40")
      expect(rows[0].at_css("button")["disabled"]).to be_nil
      expect(rows[1].text).to include("0@2", "invalid_message", "nenhum")
      expect(rows[1].at_css("button")["disabled"]).to be_present
      expect(rows[1].text).to include("Idempotency-Key")
      expect(page.css(".admin-nav a").map(&:text)).to include("DLQ")
    end

    it "mostra o erro do Broker na listagem, sem 500" do
      stub_request(:get, dlq_url("/dlq/messages")).with(query: hash_including({})).to_raise(Errno::ECONNREFUSED)

      get "/admin/dlq", headers: admin_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Não foi possível ler a DLQ", "Broker indisponível")
    end

    it "reprocessa e redireciona com o offset novo" do
      stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
      stub_dlq_reprocess(1, 7, destination_offset: 41)

      post "/admin/dlq/1/7/reprocess", headers: admin_headers

      expect(response).to redirect_to("/admin/dlq")
      expect(flash[:notice]).to eq("Mensagem 1@7 republicada em agent.outbound/2@41")
      event = Tenancy.with_brand(brand) { AuditEvent.find_by!(action: "dlq.reprocessed") }
      expect(event.payload.dig("payload", "operator_name")).to eq(AdminHelpers::ADMIN_USER)
    end

    it "redireciona com o erro quando o reprocessamento não é feito" do
      stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id, reason: "invalid_message") ])

      post "/admin/dlq/1/7/reprocess", headers: admin_headers

      expect(response).to redirect_to("/admin/dlq")
      expect(flash[:alert]).to include("Reprocessamento não feito", "invalid_message")
    end
  end
end

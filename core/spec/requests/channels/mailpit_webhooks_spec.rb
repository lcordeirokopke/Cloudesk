require "rails_helper"

RSpec.describe "Webhook do Mailpit", type: :request do
  let(:summary) { { "ID" => "mailpit-1", "MessageID" => "abc@lojista.test", "Subject" => "Repasse" }.to_json }

  def credentials(user: ENV.fetch("MAILPIT_WEBHOOK_USER"), password: ENV.fetch("MAILPIT_WEBHOOK_PASSWORD"))
    ActionController::HttpAuthentication::Basic.encode_credentials(user, password)
  end

  def ingest_jobs
    jobs_of(Channels::Email::IngestJob)
  end

  it "com basic auth, enfileira o IngestJob com o ID do Mailpit e responde 200" do
    expect do
      post "/channels/email/mailpit", params: summary,
                                      headers: { "Content-Type" => "application/json", "Authorization" => credentials }
    end.to change { ingest_jobs.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(ingest_jobs.order(:id).last.arguments.fetch("arguments")).to eq([ "mailpit-1" ])
  end

  it "sem basic auth responde 401 e não enfileira" do
    expect do
      post "/channels/email/mailpit", params: summary, headers: { "Content-Type" => "application/json" }
    end.not_to(change { ingest_jobs.count })

    expect(response).to have_http_status(:unauthorized)
  end

  it "com senha errada responde 401" do
    post "/channels/email/mailpit", params: summary,
                                    headers: { "Content-Type" => "application/json", "Authorization" => credentials(password: "errada") }

    expect(response).to have_http_status(:unauthorized)
  end
end

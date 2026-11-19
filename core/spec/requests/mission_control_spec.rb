require "rails_helper"

RSpec.describe "Mission Control - Jobs", type: :request do
  let(:headers) { { "User-Agent" => ChannelHelpers::MODERN_BROWSER } }
  let(:user) { AgentHelpers::ENVIRONMENT.fetch("MISSION_CONTROL_USER") }
  let(:password) { AgentHelpers::ENVIRONMENT.fetch("MISSION_CONTROL_PASSWORD") }

  # As credenciais são lidas na inicialização; o teste usa as do apoio.
  around do |example|
    previous = [ MissionControl::Jobs.http_basic_auth_user, MissionControl::Jobs.http_basic_auth_password ]
    MissionControl::Jobs.http_basic_auth_user = user
    MissionControl::Jobs.http_basic_auth_password = password
    example.run
  ensure
    MissionControl::Jobs.http_basic_auth_user, MissionControl::Jobs.http_basic_auth_password = previous
  end

  def basic_auth(user, password)
    ActionController::HttpAuthentication::Basic.encode_credentials(user, password)
  end

  it "responde 401 sem credencial" do
    get "/jobs", headers: headers

    expect(response).to have_http_status(:unauthorized)
  end

  it "responde 401 com senha errada" do
    get "/jobs", headers: headers.merge("Authorization" => basic_auth(user, "errada"))

    expect(response).to have_http_status(:unauthorized)
  end

  it "responde 200 com a credencial" do
    authorized = headers.merge("Authorization" => basic_auth(user, password))
    get "/jobs", headers: authorized
    follow_redirect!(headers: authorized) while response.redirect?

    expect(response).to have_http_status(:ok)
  end
end

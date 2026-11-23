require "rails_helper"
require "rack/test"

RSpec.describe Observability::App do
  include Rack::Test::Methods

  let(:registry) { Observability::Registry.build }
  let(:app) { described_class.new(registry: registry) }

  it "GET /metrics responde 200 com as famílias registradas no texto do Prometheus" do
    registry.replace(:cloudesk_conversations_open, { { brand: "infinitepay", queue: "geral", state: "with_ai" } => 3 })

    get "/metrics"

    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to eq("text/plain; version=0.0.4")
    families = Observability::Registry::HISTOGRAMS.keys + Observability::Registry::GAUGES.keys +
               Observability::Registry::COUNTERS.keys
    families.each { |name| expect(last_response.body).to include("# TYPE #{name} ") }
    expect(last_response.body).to include(%(cloudesk_conversations_open{brand="infinitepay",queue="geral",state="with_ai"} 3.0))
  end

  it "GET /up responde 200" do
    get "/up"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq("ok")
  end

  it "responde 404 nas outras rotas e métodos" do
    get "/outra"
    expect(last_response.status).to eq(404)

    post "/metrics"
    expect(last_response.status).to eq(404)
  end
end

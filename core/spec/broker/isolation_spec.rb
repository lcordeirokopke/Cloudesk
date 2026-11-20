require "broker_helper"
require "open3"
require "rbconfig"

# O Broker roda sem Rails e sem banco. Cada caso carrega o Broker num processo Ruby novo, como os
# serviços broker-web (broker.ru) e broker-consumer (CLI do Karafka, que carrega o karafka.rb), e
# confere que Rails e Active Record não ficam definidos.
RSpec.describe "Isolamento do Broker", broker: true do
  def run_ruby(script, env)
    Open3.capture2e(env, RbConfig.ruby, "-rbundler/setup", "-e", script, chdir: File.expand_path("../..", __dir__))
  end

  let(:env) { BrokerHelpers::ENVIRONMENT.merge("CONTRACTS_PATH" => ENV.fetch("CONTRACTS_PATH"), "KARAFKA_REQUIRE_RAILS" => nil) }
  let(:report) { 'puts [defined?(Rails).inspect, defined?(ActiveRecord).inspect, defined?(Broker::WebhookApp).inspect].join(" ")' }

  it "lib/broker.rb não carrega Rails nem Active Record" do
    output, status = run_ruby(%(require "./lib/broker"; #{report}), env)

    expect(status).to be_success, output
    expect(output.lines.last.strip).to eq('nil nil "constant"')
  end

  it "o CLI do Karafka com KARAFKA_REQUIRE_RAILS=false carrega só o karafka.rb" do
    script = %(require "karafka"; Karafka::Cli::Base.load; #{report})
    output, status = run_ruby(script, env.merge("KARAFKA_REQUIRE_RAILS" => "false"))

    expect(status).to be_success, output
    expect(output.lines.last.strip).to eq('nil nil "constant"')
  end
end

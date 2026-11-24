require "rails_helper"

# Heartbeat dos processos do Solid Queue e limiar para dar um processo como morto
# (config/application.rb), e um processo por worker nas configurações das filas.
RSpec.describe "Configuração do Solid Queue" do
  it "manda heartbeat a cada 5 s e dá o processo como morto depois de 30 s sem heartbeat" do
    expect(SolidQueue.process_heartbeat_interval).to eq(5.seconds)
    expect(SolidQueue.process_alive_threshold).to eq(30.seconds)
  end

  %w[config/queue.yml config/queue_webhooks.yml].each do |path|
    it "#{path} roda um processo por worker" do
      config = YAML.load(ERB.new(Rails.root.join(path).read).result, aliases: true)

      expect(config.dig("development", "workers").map { |worker| worker["processes"] }).to all(eq(1))
    end
  end
end

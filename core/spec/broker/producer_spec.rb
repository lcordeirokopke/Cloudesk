require "broker_helper"

RSpec.describe Broker::Producer, broker: true do
  # O WaterDrop só conecta ao Kafka na primeira publicação: o teste lê a configuração sem conectar.
  let(:producer) { described_class.build(client_id: "cloudesk-broker-spec", logger: Logger.new(nil)) }

  after { producer.close }

  it "escolhe a partição pelo murmur2 da chave, como o aiokafka do agente e o rpk" do
    expect(producer.config.kafka).to include(partitioner: "murmur2_random")
  end

  it "confirma só com a mensagem gravada, com idempotência e prazo de 3 s" do
    expect(producer.config.kafka).to include(
      "bootstrap.servers": broker_env("KAFKA_BROKERS"),
      "client.id": "cloudesk-broker-spec",
      acks: "all",
      "enable.idempotence": true,
      "message.timeout.ms": 3_000
    )
  end
end

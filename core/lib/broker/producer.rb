module Broker
  # Produtor Kafka do Broker (WaterDrop), um por processo: o WaterDrop é thread-safe e atende todas
  # as threads do Puma do broker-web; no broker-consumer, é o produtor do Karafka, usado na DLQ.
  # acks=all e idempotência ligada: a confirmação só chega com a mensagem gravada, sem duplicata por
  # reenvio interno do produtor. message.timeout.ms de 3 s fica abaixo dos 5 s de leitura do Core
  # (Agents::BrokerClient): sem confirmação nesse prazo, o produce_sync lança e o broker-web responde
  # 503 antes de o Core desistir da requisição.
  module Producer
    MESSAGE_TIMEOUT_MS = 3_000

    module_function

    def build(client_id:, logger: Logger.new($stdout))
      WaterDrop::Producer.new do |config|
        config.logger = logger
        config.kafka = {
          "bootstrap.servers": Settings.kafka_brokers,
          "client.id": client_id,
          acks: "all",
          "enable.idempotence": true,
          "message.timeout.ms": MESSAGE_TIMEOUT_MS
        }
      end
    end
  end
end

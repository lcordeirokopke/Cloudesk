# Rackup do broker-web (bundle exec puma -C config/puma_broker.rb broker.ru). Carrega o Broker sem
# Rails (lib/broker.rb) e serve o endpoint do webhook message.created.
require_relative "lib/broker"

# Log sem buffer: a saída do contêiner não é um terminal.
$stdout.sync = true

BROKER_LOGGER = Logger.new($stdout, level: Logger::INFO)
# Um produtor por processo, compartilhado pelas threads do Puma; fechado em config/puma_broker.rb.
BROKER_PRODUCER = Broker::Producer.build(client_id: "cloudesk-broker-web", logger: BROKER_LOGGER)

run Broker::WebhookApp.new(producer: BROKER_PRODUCER, logger: BROKER_LOGGER)

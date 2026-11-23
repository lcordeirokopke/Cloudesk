# Rackup do serviço metrics (bundle exec puma -C config/puma_metrics.rb metrics.ru). Carrega o Rails,
# abre a thread de coleta (Observability::Collector, a cada 5 s) e serve GET /metrics e GET /up
# (Observability::App). Uma réplica só: o cursor das latências fica na memória do processo.
require_relative "config/environment"

# Log sem buffer: a saída do contêiner não é um terminal.
$stdout.sync = true

# Sem log de SQL neste processo: a coleta roda a cada 5 s e encheria o log/development.log, que os
# processos do Core compartilham. Os erros da coleta vão para a saída do contêiner (logger abaixo).
ActiveRecord::Base.logger = nil

registry = Observability::Registry.build
Observability::Collector.new(registry: registry, logger: Logger.new($stdout, level: Logger::INFO)).start

run Observability::App.new(registry: registry)

# Carregador do Broker: o broker-web (core/broker.ru) e o broker-consumer (core/karafka.rb) entram
# por aqui. O Broker roda sem Rails e sem banco: carrega só o contrato (lib/contract/), o contexto de
# trace (lib/trace_context.rb), a serialização JSON do Active Support usada por Contract::Schemas,
# o Karafka e o WaterDrop. Fala com o Core somente por HTTP.
# Este arquivo e a pasta lib/broker/ ficam fora do autoload do Core (config/application.rb).

# Sem esta chave, o require "karafka" faz require "rails", e o CLI do Karafka carrega
# config/environment.rb quando acha o arquivo (Karafka.rails? e Karafka::Cli::Base.load).
ENV["KARAFKA_REQUIRE_RAILS"] = "false"

require "json"
require "logger"
require "pathname"
require "securerandom"
require "time"
require "active_support"
require "active_support/core_ext/object/json"
require "rack"
require "karafka"

require_relative "trace_context"
require_relative "contract/schemas"
require_relative "contract/signature"
require_relative "contract/idempotency_key"

require_relative "broker/settings"
require_relative "broker/producer"
require_relative "broker/webhook_app"
require_relative "broker/core_client"
require_relative "broker/dead_letter"
require_relative "broker/actions_consumer"

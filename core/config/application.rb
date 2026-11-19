require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Cloudesk
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks middleware])

    # Contexto de trace e horário de recebimento de cada requisição HTTP.
    require_relative "../lib/middleware/trace_context_middleware"
    config.middleware.insert_after ActionDispatch::Executor, TraceContextMiddleware

    # Solid Queue no banco do app, em todos os ambientes: a gravação do estado e do job
    # acontece na mesma transação (outbox implícito).
    config.active_job.queue_adapter = :solid_queue

    # Filas próprias do Action Mailbox; o load_defaults as deixa vazias, o que manda os jobs para a
    # fila default.
    config.action_mailbox.queues.routing = :action_mailbox_routing
    config.action_mailbox.queues.incineration = :action_mailbox_incineration

    # Schema em db/structure.sql: o formato :ruby não expressa políticas, triggers e permissões.
    config.active_record.schema_format = :sql

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end

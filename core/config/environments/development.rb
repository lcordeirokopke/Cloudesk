require "active_support/core_ext/integer/time"

# Perfil de carga: com CLOUDESK_LOAD_PROFILE=1, os processos rodam sem recarregamento de código, com
# o código carregado no boot e sem os logs e as anotações de desenvolvimento, para as medidas e a
# carga do experimento.
load_profile = ENV["CLOUDESK_LOAD_PROFILE"] == "1"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = !load_profile

  # Do not eager load code on boot.
  config.eager_load = load_profile

  # Log em INFO no perfil de carga; sem ele, o padrão de desenvolvimento (DEBUG).
  config.log_level = :info if load_profile

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = !load_profile

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  config.cache_store = :solid_cache_store

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  # Make template changes take effect immediately.
  config.action_mailer.perform_caching = false

  # Set localhost to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }

  # Respostas por e-mail saem por SMTP para o Mailpit.
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: ENV.fetch("SMTP_HOST", "localhost"),
    port: ENV.fetch("SMTP_PORT", "1025").to_i
  }

  # Os clientes da rede do Compose (agente, Broker, simulador e Mailpit) chamam o Core pelo
  # balanceador (Host: web-lb); o nome do serviço web continua aceito.
  config.hosts << "web-lb"
  config.hosts << "web"

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = !load_profile

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = !load_profile

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = !load_profile

  # Highlight code that triggered redirect in logs.
  config.action_dispatch.verbose_redirect_logs = !load_profile

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = !load_profile

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end

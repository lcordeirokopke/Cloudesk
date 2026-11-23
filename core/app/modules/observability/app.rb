module Observability
  # App Rack do serviço metrics, sem autenticação e só na rede do Compose.
  #
  #   GET /metrics  texto do Prometheus com o registro (Observability::Registry)
  #   GET /up       healthcheck
  #   404 no restante
  class App
    def initialize(registry:)
      @registry = registry
    end

    def call(env)
      return [ 404, { "content-type" => "text/plain" }, [ "not found" ] ] unless env["REQUEST_METHOD"] == "GET"

      case env["PATH_INFO"]
      when "/metrics"
        [ 200, { "content-type" => Prometheus::Client::Formats::Text::CONTENT_TYPE }, [ @registry.render ] ]
      when "/up"
        [ 200, { "content-type" => "text/plain" }, [ "ok" ] ]
      else
        [ 404, { "content-type" => "text/plain" }, [ "not found" ] ]
      end
    end
  end
end

# Apoio aos testes da saída ao Broker e do painel do Mission Control: endereço e segredos fixos.
module AgentHelpers
  # Valores dos testes; substituem os do ambiente do contêiner.
  ENVIRONMENT = {
    "BROKER_WEBHOOK_URL" => "http://broker.test/webhooks/message-created",
    "BROKER_WEBHOOK_SECRET" => "broker-webhook-secret-de-teste",
    "MISSION_CONTROL_USER" => "admin",
    "MISSION_CONTROL_PASSWORD" => "mission-control-password-de-teste"
  }.freeze

  def broker_webhook_url
    ENVIRONMENT.fetch("BROKER_WEBHOOK_URL")
  end

  def broker_webhook_secret
    ENVIRONMENT.fetch("BROKER_WEBHOOK_SECRET")
  end

  # Header de uma requisição registrada pelo webmock, sem diferenciar maiúsculas.
  def request_header(request, name)
    request.headers.find { |key, _| key.casecmp?(name) }&.last
  end

  # Confere a assinatura de uma requisição registrada pelo webmock.
  def verify_broker_signature!(request, path: URI(broker_webhook_url).request_uri, now: Time.now)
    Contract::Signature.verify!(
      secret: broker_webhook_secret,
      timestamp: request_header(request, Contract::Signature::TIMESTAMP_HEADER),
      signature: request_header(request, Contract::Signature::SIGNATURE_HEADER),
      method: request.method.to_s.upcase, path: path, body: request.body, now: now
    )
  end
end

RSpec.configure do |config|
  config.include AgentHelpers

  config.before(:suite) { ENV.update(AgentHelpers::ENVIRONMENT) }
end

# Apoio aos testes da integração com o Broker e o agente e do painel do Mission Control: endereço e
# segredos fixos, assinatura das chamadas à API do agente e montagem de ações do contrato.
module AgentHelpers
  # Valores dos testes; substituem os do ambiente do contêiner.
  ENVIRONMENT = {
    "BROKER_WEBHOOK_URL" => "http://broker.test/webhooks/message-created",
    "BROKER_WEBHOOK_SECRET" => "broker-webhook-secret-de-teste",
    "AGENT_ACTIONS_SECRET" => "agent-actions-secret-de-teste",
    "AGENT_CONTEXT_SECRET" => "agent-context-secret-de-teste",
    "MISSION_CONTROL_USER" => "admin",
    "MISSION_CONTROL_PASSWORD" => "mission-control-password-de-teste"
  }.freeze

  def broker_webhook_url
    ENVIRONMENT.fetch("BROKER_WEBHOOK_URL")
  end

  def broker_webhook_secret
    ENVIRONMENT.fetch("BROKER_WEBHOOK_SECRET")
  end

  def agent_actions_secret
    ENVIRONMENT.fetch("AGENT_ACTIONS_SECRET")
  end

  def agent_context_secret
    ENVIRONMENT.fetch("AGENT_CONTEXT_SECRET")
  end

  # Headers assinados de uma chamada à API do agente.
  def agent_signed_headers(secret:, method:, path:, body: "", now: Time.now)
    Contract::Signature.headers(secret: secret, method: method, path: path, body: body, now: now)
  end

  # Ação do contrato sobre a conversa, a partir do exemplo examples/action/valid/<example>.json de
  # contracts/v1: a marca, a conversa, o evento de entrada e a sequência vêm da conversa (a última
  # mensagem do lojista), e os atributos informados substituem os do exemplo.
  def agent_action(conversation, example: "reply", **attributes)
    example = JSON.parse(Contract::Schemas.root.join("examples", "action", "valid", "#{example}.json").read)
    inbound = last_customer_event(conversation)
    example.merge(
      "brand" => Brand.find(conversation.brand_id).slug,
      "conversation_id" => conversation.id,
      "inbound_event_id" => inbound&.event_id || SecureRandom.uuid_v7,
      "based_on_sequence" => inbound&.payload&.fetch("sequence") || 1
    ).merge(attributes.deep_stringify_keys)
  end

  # message.created da última mensagem do lojista na conversa.
  def last_customer_event(conversation)
    Tenancy.with_brand(conversation.brand_id) do
      message = Message.where(conversation_id: conversation.id, author: "customer").order(sequence: :desc).first
      message && AuditEvent.find_by(action: "message.created", target_type: "Message", target_id: message.id)
    end
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

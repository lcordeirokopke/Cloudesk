require "net/http"

# Prova da API do agente sem o Broker: monta, assina e envia uma ação à API de ações e lê o
# contexto assinado da conversa, como fariam o broker-consumer e o agente.
#
#   bin/rails agent:context CONVERSATION=<id>
#   bin/rails agent:action CONVERSATION=<id> TYPE=reply TEXT="Seu repasse está agendado."
#   bin/rails agent:action CONVERSATION=<id> TYPE=categorize CATEGORY=maquininha
#   bin/rails agent:action CONVERSATION=<id> TYPE=escalate REASON=repasse_nao_localizado SUMMARY="..."
#   bin/rails agent:action CONVERSATION=<id> TYPE=resolve [REASON=...]
#
# Por padrão, a ação vem do message.created da última mensagem do lojista: inbound_event_id é o
# event_id dele e based_on_sequence é a sequência dele. BASED_ON e INBOUND_EVENT_ID substituem os
# dois valores. Os carimbos de horário e o traceparent são gerados na hora; ferramentas, nenhuma.
# A mesma ação enviada de novo tem a mesma Idempotency-Key e recebe o resultado da primeira.
#
# Endereço do Core: ENV["CORE_URL"], padrão http://localhost:3000 (o próprio web, quando a task roda
# no contêiner dele). Segredos: AGENT_ACTIONS_SECRET e AGENT_CONTEXT_SECRET.
module AgentTask
  DEFAULT_CORE_URL = "http://localhost:3000".freeze

  module_function

  def core_url
    ENV.fetch("CORE_URL", DEFAULT_CORE_URL)
  end

  # Marca e conversa, procurando a conversa em cada marca.
  def find_conversation(conversation_id)
    raise ArgumentError, "informe CONVERSATION=<id>" if conversation_id.to_s.empty?

    Brand.order(:slug).each do |brand|
      conversation = Tenancy.with_brand(brand) { Conversation.find_by(id: conversation_id) }
      return [ brand, conversation ] if conversation
    end
    raise ArgumentError, "conversa #{conversation_id} não encontrada"
  end

  def build_action(brand, conversation, env)
    type = env.fetch("TYPE", "reply")
    inbound = last_customer_event(brand, conversation)
    now = Time.current.utc.iso8601(3)

    action = {
      "type" => type,
      "inbound_event_id" => env.fetch("INBOUND_EVENT_ID") { inbound&.event_id },
      "brand" => brand.slug,
      "conversation_id" => conversation.id,
      "based_on_sequence" => Integer(env.fetch("BASED_ON") { inbound&.payload&.fetch("sequence") }),
      "tools" => [],
      "timestamps" => {
        "broker_received_at" => now, "kafka_appended_at" => now, "agent_consumed_at" => now, "agent_published_at" => now
      },
      "traceparent" => TraceContext.generate.to_s
    }
    action.merge(type_fields(type, env))
  end

  def type_fields(type, env)
    case type
    when "reply" then { "text" => env.fetch("TEXT", "Resposta de teste do agente.") }
    when "categorize" then { "category" => env.fetch("CATEGORY") }
    when "resolve" then env["REASON"] ? { "reason" => env["REASON"] } : {}
    when "escalate"
      {
        "reason" => env.fetch("REASON", "teste_manual"),
        "summary" => env.fetch("SUMMARY", "Escalação de teste enviada pela task agent:action."),
        "context" => {
          "intent" => "teste_manual", "entities" => {}, "tools" => [], "attempts" => [], "sentiment" => "neutral",
          "suggested_next_step" => "Assumir a conversa", "confidence" => 0.5
        }
      }
    else raise ArgumentError, "TYPE desconhecido: #{type}"
    end
  end

  def last_customer_event(brand, conversation)
    Tenancy.with_brand(brand) do
      message = Message.where(conversation_id: conversation.id, author: "customer").order(sequence: :desc).first
      message && AuditEvent.find_by(action: "message.created", target_type: "Message", target_id: message.id)
    end
  end

  def send_action(action)
    body = Contract::Schemas.validate!("action", action).to_json
    uri = URI.join(core_url, "/api/v1/agent/actions")
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["traceparent"] = action.fetch("traceparent")
    request[Contract::IdempotencyKey::HEADER] = Contract::IdempotencyKey.for_action(action)
    sign(request, Agents::Settings.agent_actions_secret, uri, body)
    request.body = body
    perform(uri, request)
  end

  def read_context(brand, conversation)
    uri = URI.join(core_url, Contract::MessageCreated.context_url(brand.slug, conversation.id))
    request = Net::HTTP::Get.new(uri)
    sign(request, Agents::Settings.agent_context_secret, uri, "")
    perform(uri, request)
  end

  def sign(request, secret, uri, body)
    Contract::Signature.headers(secret: secret, method: request.method, path: uri.request_uri, body: body)
                       .each { |name, value| request[name] = value }
  end

  def perform(uri, request)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    puts "#{request.method} #{uri.request_uri} -> #{response.code}"
    puts pretty(response.body)
    response
  end

  def pretty(body)
    JSON.pretty_generate(JSON.parse(body.to_s))
  rescue JSON::ParserError
    body
  end
end

namespace :agent do
  desc "Lê o contexto assinado da conversa (CONVERSATION=<id>)"
  task context: :environment do
    brand, conversation = AgentTask.find_conversation(ENV["CONVERSATION"])
    AgentTask.read_context(brand, conversation)
  end

  desc "Monta, assina e envia uma ação do agente (CONVERSATION=<id> TYPE=reply|escalate|categorize|resolve)"
  task action: :environment do
    brand, conversation = AgentTask.find_conversation(ENV["CONVERSATION"])
    action = AgentTask.build_action(brand, conversation, ENV)
    puts "Idempotency-Key: #{Contract::IdempotencyKey.for_action(action)}"
    AgentTask.send_action(action)
  end
end

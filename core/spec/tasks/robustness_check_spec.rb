require "rails_helper"
require "rake"

# Task robustness:check: confere no Core, desde SINCE, respostas e entregas sem duplicação,
# idempotência sem repetição e mensagens do lojista enviadas ao agente com ação.
RSpec.describe "robustness:check" do
  let(:brand) { infinitepay }
  let(:start) { Time.zone.parse("2026-12-01 10:00:00") }
  let(:fees) { "Qual a taxa do crédito parcelado em 12x?" }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("robustness:check")
  end

  around { |example| travel_to(start + 1.minute) { example.run } }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  # Mensagem do lojista no chat; devolve a conversa.
  def customer(text = fees)
    external_id = SecureRandom.uuid
    Conversations::Intake.call(inbound_message(brand: brand, channel: "chat", identity: "app-rb-#{SecureRandom.hex(6)}",
                                               text: text, external_id: external_id))
    in_brand { Conversation.find(Message.find_by!(channel: "chat", external_id: external_id).conversation_id) }
  end

  def agent_reply(conversation)
    action = agent_action(conversation, example: "reply", text: "As taxas da sua conta são: débito 1,37%.")
    Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
    action
  end

  def deliver_last_reply(conversation)
    message = in_brand { Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last }
    job = jobs_of(Channels::DeliveryJob).find { |item| job_arguments(item)["message_id"] == message.id }
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
  end

  # Segundo agent.reply para a mesma ação, como a ação aplicada duas vezes.
  def duplicate_reply(conversation, action)
    Audit::Command.call(brand: brand, type: "agent.reply", actor_type: "ai") do |change|
      message = Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last
      change.target = message
      change.conversation = Conversation.find(conversation.id)
      change.payload = { idempotency_key: Contract::IdempotencyKey.for_action(action), action: action }
    end
  end

  def run_check
    RobustnessCheck.run(since: start.utc.iso8601)
  end

  def failed(results)
    results.reject(&:ok).map(&:label)
  end

  it "cenário limpo: tudo ok e código 0" do
    conversation = customer
    agent_reply(conversation)
    deliver_last_reply(conversation)

    results = run_check

    expect(results.reject(&:ok).map { |result| "#{result.label}: #{result.found}" }).to eq([])
    expect(RobustnessCheck.report(results, StringIO.new)).to be(true)
  end

  it "falha com agent.reply duplicado para o mesmo inbound_event_id" do
    conversation = customer
    action = agent_reply(conversation)
    deliver_last_reply(conversation)
    duplicate_reply(conversation, action)

    expect(failed(run_check)).to eq([ "nenhuma resposta ai duplicada", "nenhuma idempotência repetida" ])
  end

  it "falha com message.delivered duplicado" do
    conversation = customer
    agent_reply(conversation)
    2.times { deliver_last_reply(conversation) }

    expect(failed(run_check)).to eq([ "nenhuma entrega duplicada" ])
  end

  it "falha com mensagem enviada ao agente sem ação e lista a mensagem" do
    conversation = customer
    message_id = in_brand { Message.find_by!(conversation_id: conversation.id, author: "customer").id }

    results = run_check

    expect(failed(results)).to eq([ "mensagens sem ação" ])
    expect(results.last.found).to eq("1 (infinitepay:#{message_id})")
  end

  it "a escalação ai_timeout depois da mensagem cobre a mensagem sem ação" do
    conversation = customer
    travel (conversation.sla_minutes + 1).minutes
    Conversations::AiTimeoutSweepJob.perform_now

    expect(in_brand { conversation.reload.state }).to eq("awaiting_human")
    expect(failed(run_check)).to eq([])
  end

  it "a ação sobre uma mensagem mais nova cobre a mensagem anterior" do
    conversation = customer
    Conversations::Intake.call(inbound_message(brand: brand, channel: "chat", text: "Outra pergunta",
                                               identity: in_brand { ContactIdentity.find_by!(contact_id: conversation.contact_id).value }))
    agent_reply(conversation)

    expect(failed(run_check)).to eq([])
  end

  it "ignora mensagens anteriores a SINCE" do
    travel_to(start - 1.hour)
    customer
    travel_to(start + 1.minute)

    expect(failed(run_check)).to eq([])
  end

  it "imprime ok ou falhou por expectativa" do
    customer
    io = StringIO.new

    expect(RobustnessCheck.report(run_check, io)).to be(false)
    expect(io.string.lines.map { |line| line.split.first }).to eq(%w[ok ok ok falhou])
  end

  it "exige SINCE" do
    expect { RobustnessCheck.run(since: nil) }.to raise_error(ArgumentError, /SINCE/)
  end
end

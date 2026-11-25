require "rails_helper"
require "rake"

# Task experiment:export: um CSV por consulta com mensagens, ações, entregas e eventos das duas marcas.
RSpec.describe "experiment:export" do
  let(:fees) do
    {
      "infinitepay" => "Qual a taxa do crédito parcelado em 12x?",
      "jim" => "What is the fee for credit card installments?"
    }
  end

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("experiment:export")
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.join(dir, "export")
      previous = ENV["DIR"]
      example.run
    ensure
      ENV["DIR"] = previous
    end
  end

  # Mensagem do lojista no chat; devolve a Message gravada.
  def customer(brand, identity: "app-exp-#{SecureRandom.hex(6)}")
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "chat", identity: identity, text: fees.fetch(brand.slug),
                      external_id: "exp-#{SecureRandom.hex(6)}")
    ).first.message
  end

  def conversation_of(brand, message)
    Tenancy.with_brand(brand) { Conversation.find(message.conversation_id) }
  end

  def process(action)
    Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
    action
  end

  def deliver_last_reply(brand, conversation)
    message = Tenancy.with_brand(brand) { Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last }
    job = jobs_of(Channels::DeliveryJob).find { |item| job_arguments(item)["message_id"] == message.id }
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
    message
  end

  def event(brand, action, conversation)
    Tenancy.with_brand(brand) { AuditEvent.where(action: action, conversation_id: conversation.id).order(:id).last }
  end

  def export
    ExperimentExport.run(dir: @dir)
  end

  # Linhas do arquivo, sem o cabeçalho, em hash por coluna; o campo vazio é nil. Nenhum valor destes
  # testes tem vírgula ou aspas.
  def rows(file)
    names, *lines = lines(file)
    lines.map { |line| names.zip(line.map(&:presence)).to_h }
  end

  def headers(file)
    lines(file).first
  end

  def lines(file)
    File.read(File.join(@dir, file), encoding: "UTF-8").lines(chomp: true).map { |line| line.split(",", -1) }
  end

  def rows_of(file, conversation)
    rows(file).select { |row| row["conversation_id"] == conversation.id }
  end

  def utc(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
  end

  it "grava cada CSV com as colunas do experimento" do
    export

    expect(headers("customer_messages.csv")).to eq(
      %w[brand message_id external_id channel conversation_id sequence created_at conversation_state event_id trace_id received_at]
    )
    expect(headers("actions.csv")).to eq(
      %w[brand action type conversation_id inbound_event_id based_on_sequence idempotency_key broker_received_at
         kafka_appended_at agent_consumed_at agent_published_at artificial_latency_ms received_at]
    )
    expect(headers("deliveries.csv")).to eq(
      %w[brand message_id author channel conversation_id in_reply_to_sequence delivered_at]
    )
    expect(headers("events.csv")).to eq(
      %w[brand action conversation_id target_id reason first_attendant queue created_at]
    )
  end

  it "grava a mensagem, a ação, a entrega e o roteamento de uma conversa atendida" do
    message = customer(infinitepay)
    conversation = conversation_of(infinitepay, message)
    action = process(agent_action(conversation, example: "reply"))
    reply = deliver_last_reply(infinitepay, conversation)
    created = last_customer_event(conversation)
    accepted = event(infinitepay, "agent.reply", conversation)
    delivered = event(infinitepay, "message.delivered", conversation)
    routed = event(infinitepay, "conversation.routed", conversation)

    export

    expect(rows_of("customer_messages.csv", conversation)).to eq([ {
      "brand" => "infinitepay", "message_id" => message.id, "external_id" => message.external_id, "channel" => "chat",
      "conversation_id" => conversation.id, "sequence" => "1", "created_at" => utc(message.created_at),
      "conversation_state" => "with_ai", "event_id" => created.event_id, "trace_id" => created.trace_id,
      "received_at" => created.payload["received_at"]
    } ])
    stamps = action.fetch("timestamps")
    expect(rows_of("actions.csv", conversation)).to eq([ {
      "brand" => "infinitepay", "action" => "agent.reply", "type" => "reply", "conversation_id" => conversation.id,
      "inbound_event_id" => created.event_id, "based_on_sequence" => "1",
      "idempotency_key" => Contract::IdempotencyKey.for_action(action),
      "broker_received_at" => stamps.fetch("broker_received_at"), "kafka_appended_at" => stamps.fetch("kafka_appended_at"),
      "agent_consumed_at" => stamps.fetch("agent_consumed_at"), "agent_published_at" => stamps.fetch("agent_published_at"),
      "artificial_latency_ms" => action.dig("model", "parameters", "artificial_latency_ms")&.to_s,
      "received_at" => accepted.payload["received_at"]
    } ])
    expect(rows_of("deliveries.csv", conversation)).to eq([ {
      "brand" => "infinitepay", "message_id" => reply.id, "author" => "ai", "channel" => "chat",
      "conversation_id" => conversation.id, "in_reply_to_sequence" => "1",
      "delivered_at" => delivered.payload.dig("payload", "delivered_at")
    } ])
    expect(rows_of("events.csv", conversation)).to eq([ {
      "brand" => "infinitepay", "action" => "conversation.routed", "conversation_id" => conversation.id,
      "target_id" => conversation.id, "reason" => nil, "first_attendant" => "ai", "queue" => "ip-suporte-geral",
      "created_at" => utc(routed.created_at)
    } ])
  end

  it "grava a escalação com o motivo e a fila de destino" do
    conversation = conversation_of(infinitepay, customer(infinitepay))
    action = process(agent_action(conversation, example: "escalate"))

    export

    escalated = rows_of("events.csv", conversation).find { |row| row["action"] == "conversation.escalated" }
    expect(escalated).to include("reason" => action.fetch("reason"), "queue" => "ip-suporte-geral", "first_attendant" => nil)
  end

  it "grava em actions.csv a ação stale e a rejected" do
    conversation = conversation_of(infinitepay, customer(infinitepay, identity: "app-exp-stale"))
    outdated = agent_action(conversation, example: "reply")
    customer(infinitepay, identity: "app-exp-stale")
    process(outdated)
    process(agent_action(conversation, example: "escalate"))
    process(agent_action(conversation, example: "reply"))

    export

    expect(rows_of("actions.csv", conversation).map { |row| [ row["action"], row["type"], row["based_on_sequence"] ] }).to eq(
      [ [ "agent.action.stale", "reply", "1" ], [ "agent.escalate", "escalate", "2" ], [ "agent.action.rejected", "reply", "2" ] ]
    )
  end

  it "grava as duas marcas sem mistura e com um cabeçalho só" do
    messages = [ infinitepay, jim ].map { |brand| [ brand, customer(brand) ] }

    counts = export

    exported = rows("customer_messages.csv")
    messages.each do |brand, message|
      expect(exported.find { |row| row["message_id"] == message.id }["brand"]).to eq(brand.slug)

      ids = Tenancy.with_brand(brand) { Message.where(author: "customer").order(:id).pluck(:id) }
      expect(exported.select { |row| row["brand"] == brand.slug }.map { |row| row["message_id"] }).to eq(ids)
    end
    expect(counts).to eq(ExperimentExport::QUERIES.keys.to_h { |file| [ file, rows(file).size ] })
  end

  it "não grava nada no banco" do
    conversation = conversation_of(infinitepay, customer(infinitepay))
    process(agent_action(conversation, example: "reply"))
    counts = lambda do
      [ SolidQueue::Job.count ] + [ infinitepay, jim ].flat_map do |brand|
        Tenancy.with_brand(brand) { [ AuditEvent.count, Message.count, Conversation.count, ProcessedEvent.count ] }
      end
    end

    expect { export }.not_to(change { counts.call })
  end

  it "a task imprime as linhas de cada arquivo" do
    ENV["DIR"] = @dir
    task = Rake::Task["experiment:export"]
    task.reenable

    expect { task.invoke }.to output(/customer_messages\.csv: \d+ linhas.*events\.csv: \d+ linhas/m).to_stdout
  end

  it "exige DIR" do
    expect { ExperimentExport.run(dir: nil) }.to raise_error(ArgumentError, /DIR/)
    expect { ExperimentExport.run(dir: " ") }.to raise_error(ArgumentError, /DIR/)
  end
end

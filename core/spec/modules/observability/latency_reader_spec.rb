require "rails_helper"

RSpec.describe Observability::LatencyReader do
  let(:brand) { infinitepay }
  let(:registry) { Observability::Registry.build }
  let(:logger) { Logger.new(IO::NULL) }
  let(:reader) { described_class.new(registry: registry, logger: logger) }
  let(:start) { Time.current.change(usec: 0) }

  before { stub_request(:post, %r{\Ahttp://whatsapp\.test/}).to_return(status: 200, body: "{}") }

  after { Current.reset }

  def stamp(offset)
    (start + offset).utc.iso8601(3)
  end

  # Mensagem do lojista recebida em start, ação do agente com carimbos a partir de start e a
  # resposta entregue em start + 0,9 s. Devolve a conversa e a mensagem da resposta.
  def chain(target = brand, index: 0, model: { "name" => "agent-mock", "version" => "0.1.0", "parameters" => { "artificial_latency_ms" => 500 } },
            author: "ai", deliver_at: 0.9)
    Current.reset
    Current.traceparent = TraceContext.generate
    travel_to(start)
    contact = seed_contact(target, index)
    conversation = Conversations::Intake.call(
      inbound_message(brand: target, channel: "whatsapp", identity: identity_of(contact, "whatsapp"),
                      text: "Minha maquininha não liga", received_at: start)
    ).first.conversation
    expect(conversation.state).to eq("with_ai")

    reply = author == "ai" ? agent_reply(conversation, model) : direct_reply(conversation, author)
    travel_to(start + deliver_at, with_usec: true)
    deliver(target, reply)
    [ conversation, reply ]
  end

  def agent_reply(conversation, model)
    action = agent_action(conversation, example: "reply", tools: [], timestamps: {
      "broker_received_at" => stamp(0.1), "kafka_appended_at" => stamp(0.12),
      "agent_consumed_at" => stamp(0.15), "agent_published_at" => stamp(0.75)
    })
    action = model ? action.merge("model" => model) : action.except("model")
    travel_to(start + 0.8, with_usec: true)
    Current.received_at = start + 0.8
    result = Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
    expect(result.status).to eq(:ok)
    Tenancy.with_brand(conversation.brand_id) do
      Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last
    end
  end

  def direct_reply(conversation, author)
    Tenancy.with_brand(conversation.brand_id) do
      Conversations::Outbound.append!(conversation: Conversation.find(conversation.id), author: author,
                                      text: "Aguarde", in_reply_to_sequence: 1)
    end
  end

  def deliver(target, message)
    job = jobs_of(Channels::DeliveryJob).order(:id).to_a.reverse.find { |item| job_arguments(item)["message_id"] == message.id }
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
  end

  def collect_later(seconds = 20)
    travel_to(start + seconds)
    reader.collect
  end

  def histogram(name, **labels)
    registry[name].get(labels: labels.transform_values(&:to_s))
  end

  def count(name, **labels)
    histogram(name, **labels).fetch("+Inf")
  end

  def sum(name, **labels)
    histogram(name, **labels).fetch("sum")
  end

  it "observa os seis saltos, a ponta a ponta bruta e a descontada da latência artificial" do
    reader
    chain
    collect_later

    expected = { "core_to_broker" => 0.1, "broker_to_kafka" => 0.02, "kafka_to_agent" => 0.03, "agent" => 0.6,
                 "agent_to_core" => 0.05, "core_to_channel" => 0.1 }
    expected.each do |hop, seconds|
      expect(count(:cloudesk_hop_latency_seconds, hop: hop, channel: "whatsapp")).to eq(1.0), hop
      expect(sum(:cloudesk_hop_latency_seconds, hop: hop, channel: "whatsapp")).to be_within(0.0015).of(seconds), hop
    end
    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(1.0)
    expect(sum(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to be_within(0.0015).of(0.9)
    expect(count(:cloudesk_end_to_end_latency_seconds, channel: "whatsapp")).to eq(1.0)
    expect(sum(:cloudesk_end_to_end_latency_seconds, channel: "whatsapp")).to be_within(0.0015).of(0.4)
  end

  it "conta uma vez a entrega repetida da mesma mensagem" do
    reader
    conversation, reply = chain
    deliver(brand, reply)
    expect(audit_events_of(brand, conversation.id).count { |event| event.action == "message.delivered" }).to eq(2)
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(1.0)
  end

  it "ignora a resposta do sistema e a do analista" do
    reader
    chain(author: "system")
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(0.0)
    expect(count(:cloudesk_hop_latency_seconds, hop: "agent", channel: "whatsapp")).to eq(0.0)
  end

  it "ignora a resposta do analista" do
    reader
    Current.traceparent = TraceContext.generate
    travel_to(start)
    conversation = Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(seed_contact(brand), "whatsapp"),
                      text: "Minha maquininha não liga", received_at: start)
    ).first.conversation
    reply = Tenancy.with_brand(brand) do
      analyst = Attendant.where(kind: "human").where.not(team_id: nil).first!
      Conversations::Outbound.append!(conversation: Conversation.find(conversation.id), author: "analyst",
                                      text: "Olá", in_reply_to_sequence: 1, attendant: analyst)
    end
    deliver(brand, reply)
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(0.0)
  end

  it "sem model na ação, observa a bruta e os saltos, sem a descontada" do
    reader
    chain(model: nil)
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(1.0)
    expect(count(:cloudesk_hop_latency_seconds, hop: "agent", channel: "whatsapp")).to eq(1.0)
    expect(count(:cloudesk_end_to_end_latency_seconds, channel: "whatsapp")).to eq(0.0)
  end

  it "deixa para a próxima coleta a entrega dentro da margem de 10 s" do
    reader
    chain
    collect_later(0.9 + described_class::SETTLE_SECONDS - 1)
    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(0.0)

    collect_later(0.9 + described_class::SETTLE_SECONDS + 1)
    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(1.0)

    collect_later(60)
    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(1.0)
  end

  it "mantém um cursor por marca, sem misturar as marcas" do
    reader
    chain(brand)
    chain(jim)
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(2.0)
    collect_later(40)
    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(2.0)
  end

  it "não lê a entrega anterior à criação do leitor" do
    chain
    reader
    collect_later

    expect(count(:cloudesk_end_to_end_raw_latency_seconds, channel: "whatsapp")).to eq(0.0)
  end

  it "observa como 0 o salto negativo e registra em log" do
    output = StringIO.new
    logging_reader = described_class.new(registry: registry, logger: Logger.new(output))
    chain(deliver_at: 0.7)
    travel_to(start + 20)
    logging_reader.collect

    expect(count(:cloudesk_hop_latency_seconds, hop: "core_to_channel", channel: "whatsapp")).to eq(1.0)
    expect(sum(:cloudesk_hop_latency_seconds, hop: "core_to_channel", channel: "whatsapp")).to eq(0.0)
    expect(output.string).to include("core_to_channel negativo")
  end
end

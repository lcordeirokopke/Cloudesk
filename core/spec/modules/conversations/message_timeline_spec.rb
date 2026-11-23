require "rails_helper"

RSpec.describe Conversations::MessageTimeline do
  let(:brand) { infinitepay }
  let(:start) { Time.current.change(usec: 0) }

  before { stub_request(:post, %r{\Ahttp://whatsapp\.test/}).to_return(status: 200, body: "{}") }

  after { Current.reset }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def stamp(offset)
    (start + offset).utc.iso8601(3)
  end

  def receive(text = "Minha maquininha não liga", index: 0)
    travel_to(start)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(seed_contact(brand, index), "whatsapp"),
                      text: text, received_at: Time.current)
    ).first
  end

  def act(conversation, at:, **attributes)
    action = agent_action(conversation, example: "reply", **attributes).merge(
      "timestamps" => { "broker_received_at" => stamp(0.1), "kafka_appended_at" => stamp(0.12),
                        "agent_consumed_at" => stamp(0.15), "agent_published_at" => stamp(0.75) },
      "tools" => [ { "name" => "consultar_repasse", "input" => {}, "output" => { "status" => "pago" },
                     "started_at" => stamp(0.2), "finished_at" => stamp(0.25) } ],
      "model" => { "name" => "agent-mock", "version" => "0.1.0", "parameters" => { "artificial_latency_ms" => 500 } }
    )
    travel_to(start + at, with_usec: true)
    Current.received_at = start + at
    Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
  end

  def deliver_last_reply(conversation, at:)
    message = in_brand { Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last }
    job = jobs_of(Channels::DeliveryJob).order(:id).to_a.reverse.find { |item| job_arguments(item)["message_id"] == message.id }
    travel_to(start + at, with_usec: true)
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
  end

  def timeline(message)
    in_brand { described_class.for(Message.find(message.id)) }
  end

  it "monta os passos em ordem com os carimbos da ação, as ferramentas e a entrega" do
    Current.traceparent = TraceContext.generate
    received = receive
    act(received.conversation, at: 0.8)
    deliver_last_reply(received.conversation, at: 0.9)

    result = timeline(received.message)

    expect(result.steps.map(&:label)).to eq(
      [ "Canal → Core", "Core → Broker", "Kafka", "Agente consumiu", "Ferramenta consultar_repasse",
        "Agente publicou", "Broker → Core", "Cliente" ]
    )
    offsets = result.steps.map { |step| step.at - start }
    [ 0.0, 0.1, 0.12, 0.15, 0.2, 0.75, 0.8, 0.9 ].each_with_index do |expected, index|
      expect(offsets[index]).to be_within(0.002).of(expected), result.steps[index].label
    end
    expect(result.steps.first.detail).to eq("whatsapp")
    expect(result.steps[4].detail - start).to be_within(0.002).of(0.25)
    expect(result.steps[5].detail).to eq("latência artificial 500 ms")
    expect(result.steps[6].detail).to eq("reply")
    expect(result.without_action?).to be(false)
    expect(result.events.map(&:trace_id).uniq).to eq([ result.trace_id ])
    expect(result.events.map(&:action)).to include("message.created", "agent.reply", "message.delivered")
  end

  it "mostra no passo 7 a ação recusada" do
    Current.traceparent = TraceContext.generate
    first = receive
    action_for_first = agent_action(first.conversation, example: "reply")
    receive("Alguém pode me ajudar?")
    travel_to(start + 0.8, with_usec: true)
    Current.received_at = start + 0.8
    result = Agents::ActionProcessor.call(action: action_for_first,
                                          idempotency_key: Contract::IdempotencyKey.for_action(action_for_first))
    expect(result.body.fetch("status")).to eq("stale")

    steps = timeline(first.message).steps

    expect(steps.map(&:label)).to include("Broker → Core")
    expect(steps.find { |step| step.label == "Broker → Core" }.detail).to eq("recusada: stale (reply)")
    expect(steps.map(&:label)).not_to include("Cliente")
  end

  it "sem ação do agente, para no passo 1 e mostra os eventos do trace" do
    received = receive

    result = timeline(received.message)

    expect(result.steps.map(&:label)).to eq([ "Canal → Core" ])
    expect(result.without_action?).to be(true)
    expect(result.events.map(&:action)).to include("message.created")
    expect(result.trace_id).to be_present
  end
end

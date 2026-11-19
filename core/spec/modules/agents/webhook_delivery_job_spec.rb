require "rails_helper"

RSpec.describe Agents::WebhookDeliveryJob do
  let(:brand) { infinitepay }
  let(:requests) { [] }

  # Grava, com a conversa no estado informado, o evento do tipo informado com job de webhook.
  def create_event(state: "with_ai", type: "message.created")
    Audit::Command.call(brand: brand, type: type, actor_type: "customer", webhook: true) do |change|
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")
      conversation.transition_to!(state) unless state == "triage"
      message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
      change.target = message
      change.conversation = conversation
      change.sequence = message.sequence
      change.payload = { message: { author: "customer", channel: "whatsapp", text: "oi" } }
    end
  end

  def arguments_of(result)
    { brand_id: brand.id, event_id: result.envelope.event_id, traceparent: result.envelope.traceparent.to_s }
  end

  def stub_broker(status: 202)
    stub_request(:post, broker_webhook_url).to_return do |request|
      requests << request
      { status: status }
    end
  end

  def skipped_events
    Tenancy.with_brand(brand) { AuditEvent.where(action: "webhook.skipped").to_a }
  end

  # Jobs agendados para depois da gravação: as novas tentativas do retry_on.
  def retries
    jobs_of(described_class).where("scheduled_at > created_at")
  end

  it "usa a fila webhooks" do
    expect(described_class.new.queue_name).to eq("webhooks")
  end

  describe "com a conversa em with_ai" do
    it "envia ao Broker o corpo do contrato message.created, assinado" do
      result = create_event
      stub_broker

      described_class.perform_now(**arguments_of(result))

      expect(requests.size).to eq(1)
      body = JSON.parse(requests.first.body)
      expect(body).to eq(Contract::MessageCreated.build(result.envelope.to_h))
      expect(Contract::Schemas.valid?("webhook.message-created", body)).to be(true)
      expect(verify_broker_signature!(requests.first)).to be(true)
    end

    it "continua o trace do evento no header traceparent" do
      result = create_event
      stub_broker

      described_class.perform_now(**arguments_of(result))

      header = TraceContext.parse(request_header(requests.first, "traceparent"))
      expect(header.trace_id).to eq(result.envelope.trace_id)
      expect(header.to_s).not_to eq(result.envelope.traceparent.to_s)
    end

    it "não grava audit_event na resposta 2xx" do
      result = create_event
      stub_broker

      expect { described_class.perform_now(**arguments_of(result)) }
        .not_to(change { Tenancy.with_brand(brand) { AuditEvent.count } })
    end
  end

  describe "com a conversa fora de with_ai" do
    it "grava webhook.skipped com o estado atual e não chama o Broker" do
      result = create_event
      conversation = Tenancy.with_brand(brand) { Conversation.find(result.envelope.conversation_id) }
      Tenancy.with_brand(brand) { conversation.transition_to!("awaiting_human") }

      expect { described_class.perform_now(**arguments_of(result)) }.not_to(change { webhook_jobs.count })

      expect(a_request(:any, /broker/)).not_to have_been_made
      event = skipped_events.sole
      expect(event).to have_attributes(
        actor_type: "system", target_type: "Message", target_id: result.audit_event.target_id,
        conversation_id: conversation.id, reason: "conversa em awaiting_human"
      )
      expect(event.payload).to include("sequence" => result.envelope.sequence)
      expect(event.payload["payload"]).to eq("event_id" => result.envelope.event_id, "state" => "awaiting_human")
      expect(event.trace_id).to eq(result.envelope.trace_id)
    end

    it "não envia com a conversa em triage" do
      result = create_event(state: "triage")

      described_class.perform_now(**arguments_of(result))

      expect(a_request(:any, /broker/)).not_to have_been_made
      expect(skipped_events.sole.reason).to eq("conversa em triage")
    end
  end

  describe "falhas" do
    it "falha sem nova tentativa quando o evento não é message.created" do
      result = create_event(type: "message.delivered")

      expect { described_class.perform_now(**arguments_of(result)) }
        .to raise_error(Agents::WebhookError::Permanent, /message.delivered/)
      expect(a_request(:any, /broker/)).not_to have_been_made
      expect(retries.count).to eq(0)
    end

    it "não lê o evento com a marca errada" do
      result = create_event

      expect { described_class.perform_now(**arguments_of(result).merge(brand_id: jim.id)) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "agenda nova tentativa com backoff exponencial e jitter em erro transitório" do
      result = create_event
      stub_broker(status: 503)

      freeze_time do
        described_class.perform_now(**arguments_of(result))

        retry_job = retries.sole
        expect(retry_job.queue_name).to eq("webhooks")
        expect(job_arguments(retry_job)).to include("event_id" => result.envelope.event_id)
        expect(retry_job.scheduled_at - Time.current).to be_between(2, 2 * 1.15)
      end
    end

    it "agenda nova tentativa quando o Broker está fora do ar" do
      result = create_event
      stub_request(:post, broker_webhook_url).to_raise(Errno::ECONNREFUSED)

      described_class.perform_now(**arguments_of(result))

      expect(retries.count).to eq(1)
    end

    it "falha depois da décima tentativa, sem novo agendamento" do
      result = create_event
      stub_broker(status: 503)
      job = described_class.new(**arguments_of(result))
      # O retry_on conta as tentativas por exceção, em exception_executions.
      job.exception_executions = { [ Agents::WebhookError::Transient ].to_s => described_class::MAX_ATTEMPTS - 1 }

      expect { job.perform_now }.to raise_error(Agents::WebhookError::Transient, /503/)
      expect(retries.count).to eq(0)
    end

    it "falha sem nova tentativa quando o Broker recusa com 4xx" do
      result = create_event
      stub_broker(status: 401)

      expect { described_class.perform_now(**arguments_of(result)) }
        .to raise_error(Agents::WebhookError::Permanent, /401/)
      expect(retries.count).to eq(0)
    end
  end

  describe "backoff" do
    it "soma cerca de 17 minutos de espera nas 10 tentativas" do
      waits = (1...described_class::MAX_ATTEMPTS).map { |executions| ApplicationJob::EXPONENTIAL_BACKOFF.call(executions) }

      expect(waits.sum).to be_between(1022, 1022 * 1.15)
    end
  end
end

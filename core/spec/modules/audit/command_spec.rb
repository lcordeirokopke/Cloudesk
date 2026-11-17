require "rails_helper"

# Os exemplos rodam dentro da transação do RSpec. O comando abre um savepoint em Tenancy.with_brand:
# o erro desfaz o savepoint, como o rollback desfaz a transação, e o sucesso mantém as três gravações.
# audit_events não aceita DELETE; um exemplo com commit de verdade deixaria linhas no banco de teste.
RSpec.describe Audit::Command do
  let(:brand) { infinitepay }
  let(:conversation) do
    Tenancy.with_brand(brand) { Conversation.create!(contact: Contact.first!, channel: "whatsapp") }
  end

  after { Current.reset }

  def webhook_jobs
    SolidQueue::Job.where(class_name: "Agents::WebhookDeliveryJob")
  end

  def counts
    Tenancy.with_brand(brand) do
      { messages: Message.count, audit_events: AuditEvent.count, jobs: webhook_jobs.count,
        last_sequence: Conversation.find(conversation.id).last_sequence }
    end
  end

  def create_message(body: "Meu repasse de ontem não caiu", **options)
    described_class.call(brand: brand, type: "message.created", actor_type: "customer", webhook: true, **options) do |change|
      message = conversation.append_message!(channel: "whatsapp", author: "customer", body: body)
      change.target = message
      change.conversation = conversation
      change.sequence = message.sequence
      change.payload = { message: { author: "customer", channel: "whatsapp", text: body } }
      yield if block_given?
      message
    end
  end

  def job_arguments(job)
    job.arguments.fetch("arguments").first
  end

  describe "com sucesso" do
    it "grava a mudança de estado, o audit_event e o job de webhook juntos" do
      before_counts = counts

      result = create_message

      expect(counts).to eq(
        messages: before_counts[:messages] + 1,
        audit_events: before_counts[:audit_events] + 1,
        jobs: before_counts[:jobs] + 1,
        last_sequence: 1
      )
      expect(result.value).to be_a(Message).and be_persisted
    end

    it "grava o audit_event com ator, ação, alvo, conversa, envelope completo e trace_id" do
      result = create_message
      audit_event = Tenancy.with_brand(brand) { AuditEvent.find(result.audit_event.id) }

      expect(audit_event).to have_attributes(
        event_id: result.envelope.event_id,
        actor_type: "customer",
        action: "message.created",
        target_type: "Message",
        target_id: result.value.id,
        conversation_id: conversation.id,
        trace_id: result.envelope.trace_id
      )
      expect(audit_event.payload).to eq(result.envelope.to_h)
      expect(audit_event.payload).to include(
        "type" => "message.created",
        "brand" => "infinitepay",
        "conversation_id" => conversation.id,
        "sequence" => 1,
        "payload" => { "message" => { "author" => "customer", "channel" => "whatsapp",
                                      "text" => "Meu repasse de ontem não caiu" } }
      )
    end

    it "enfileira o job na fila webhooks com marca, event_id e traceparent" do
      result = create_message
      job = webhook_jobs.order(:id).last

      expect(job.queue_name).to eq("webhooks")
      expect(job.ready_execution).to be_present
      expect(job_arguments(job)).to include(
        "brand_id" => brand.id,
        "event_id" => result.envelope.event_id,
        "traceparent" => result.envelope.traceparent.to_s
      )
    end

    it "grava antes, depois, motivo, regra e versão de uma decisão" do
      result = nil
      Tenancy.with_brand(brand) do
        rule = RoutingRule.order(:position).first!

        result = described_class.call(
          brand: brand, type: "conversation.routed", actor_type: "system", reason: "regra casou", routing_rule: rule
        ) do |change|
          change.before = { state: conversation.state }
          conversation.transition_to!("with_ai")
          change.after = { state: conversation.state }
          change.target = conversation
          change.conversation = conversation
        end

        expect(result.audit_event).to have_attributes(
          before: { "state" => "triage" },
          after: { "state" => "with_ai" },
          reason: "regra casou",
          routing_rule_id: rule.id,
          rule_version: rule.version
        )
      end
    end

    it "não enfileira job quando o comando não tem evento de saída" do
      conversation
      before_jobs = webhook_jobs.count

      described_class.call(brand: brand, type: "conversation.routed", actor_type: "system") do |change|
        conversation.transition_to!("with_ai")
        change.target = conversation
        change.conversation = conversation
      end

      expect(webhook_jobs.count).to eq(before_jobs)
    end
  end

  describe "com falha" do
    it "não deixa mudança de estado, audit_event nem job quando o bloco falha" do
      before_counts = counts

      expect { create_message { raise "falha depois de gravar a mensagem" } }.to raise_error("falha depois de gravar a mensagem")

      expect(counts).to eq(before_counts)
    end

    it "não deixa mudança de estado nem job quando o audit_event não é gravado" do
      before_counts = counts
      allow(AuditEvent).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect { create_message }.to raise_error(ActiveRecord::RecordInvalid)

      expect(counts).to eq(before_counts)
    end

    it "não deixa mudança de estado nem audit_event quando o job não é enfileirado" do
      before_counts = counts
      allow(Agents::WebhookDeliveryJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid, "fila indisponível")

      expect { create_message }.to raise_error(ActiveRecord::StatementInvalid)

      expect(counts).to eq(before_counts)
    end

    it "recusa o comando que não informa o alvo" do
      before_counts = counts

      expect do
        described_class.call(brand: brand, type: "message.created", actor_type: "customer") do |_change|
          conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
        end
      end.to raise_error(ArgumentError)

      expect(counts).to eq(before_counts)
    end
  end

  describe "outbox implícito" do
    it "o job é gravado na transação do comando, sem enqueue_after_transaction_commit" do
      expect(ApplicationJob.enqueue_after_transaction_commit).to be(false)
      expect(Agents::WebhookDeliveryJob.enqueue_after_transaction_commit).to be(false)
      expect(SolidQueue::Record.connection_pool).to equal(ApplicationRecord.connection_pool)
    end
  end

  describe "contexto de trace" do
    it "grava no evento e no job o trace da requisição corrente" do
      Current.traceparent = TraceContext.continue("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
      Current.received_at = Time.utc(2026, 11, 13, 14, 2, 11.482r)

      result = create_message
      job = webhook_jobs.order(:id).last

      expect(result.audit_event.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      expect(result.audit_event.payload).to include(
        "traceparent" => Current.traceparent.to_s,
        "received_at" => "2026-11-13T14:02:11.482Z"
      )
      expect(TraceContext.parse(job_arguments(job).fetch("traceparent")).trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "inicia um trace quando não existe requisição corrente" do
      result = create_message

      expect(result.audit_event.trace_id).to match(/\A\h{32}\z/)
      expect(TraceContext.parse(result.audit_event.payload.fetch("traceparent"))).to be_present
    end
  end
end

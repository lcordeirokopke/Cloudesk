require "rails_helper"

RSpec.describe Agents::RecoverInterruptedWebhooksJob do
  let(:brand) { infinitepay }

  def create_webhook_job
    Audit::Command.call(brand: brand, type: "message.created", actor_type: "customer", webhook: true) do |change|
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")
      conversation.transition_to!("with_ai")
      message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
      change.target = message
      change.conversation = conversation
      change.sequence = message.sequence
      change.payload = { message: { author: "customer", channel: "whatsapp", text: "oi" } }
    end
    webhook_jobs.order(:id).last
  end

  # Leva o job à fila de falhas com o erro informado, como o Solid Queue faz.
  def fail_job(job, error)
    job.ready_execution&.destroy!
    job.failed_with(error)
    job.reload
  end

  [
    SolidQueue::Processes::ProcessPrunedError.new(Time.current),
    SolidQueue::Processes::ProcessMissingError.new
  ].each do |error|
    it "devolve à fila o job de webhook que falhou com #{error.class.name.demodulize}" do
      job = fail_job(create_webhook_job, error)

      expect(described_class.perform_now).to eq(1)

      job.reload
      expect(job.failed_execution).to be_nil
      expect(job.ready_execution).to be_present
      expect(job.arguments).to include("executions" => 0, "exception_executions" => {})
    end
  end

  it "devolve à fila o job de webhook que falhou com ProcessExitError" do
    status = instance_double(Process::Status, exitstatus: 137, signaled?: true, termsig: 9, pid: 42, to_s: "pid 42 SIGKILL")
    error = SolidQueue::Processes::ProcessExitError.new(status)
    job = fail_job(create_webhook_job, error)

    expect(described_class.perform_now).to eq(1)
    expect(job.reload.failed_execution).to be_nil
  end

  it "mantém na fila de falhas o job de webhook que esgotou as tentativas" do
    job = fail_job(create_webhook_job, Agents::WebhookError::Transient.new("Broker respondeu 503"))

    expect(described_class.perform_now).to eq(0)
    expect(job.reload.failed_execution).to be_present
  end

  it "mantém na fila de falhas outros jobs interrompidos pela morte do processo" do
    Channels::Email::IngestJob.perform_later("mailpit-id")
    job = jobs_of(Channels::Email::IngestJob).order(:id).last
    fail_job(job, SolidQueue::Processes::ProcessPrunedError.new(Time.current))

    expect(described_class.perform_now).to eq(0)
    expect(job.reload.failed_execution).to be_present
  end

  it "roda a cada minuto pelo jobs-default" do
    tasks = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

    expect(tasks.dig("development", "recover_interrupted_webhooks"))
      .to include("class" => described_class.name, "queue" => "default", "schedule" => "every minute")
    expect(tasks.dig("production", "recover_interrupted_webhooks")).to be_present
  end
end

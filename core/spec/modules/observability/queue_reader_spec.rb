require "rails_helper"

RSpec.describe Observability::QueueReader do
  let(:registry) { Observability::Registry.build }
  let(:reader) { described_class.new(registry: registry) }
  let(:start) { Time.utc(2026, 11, 20, 12, 0) }

  # As tabelas do Solid Queue começam vazias em cada exemplo; a transação do exemplo desfaz tudo.
  before { SolidQueue::Job.delete_all }

  around { |example| travel_to(start) { example.run } }

  def value(name, **labels)
    registry.value(name, labels)
  end

  def enqueue(job_class, *arguments, **options)
    job_class.set(**options).perform_later(*arguments)
    jobs_of(job_class).order(:id).last
  end

  def fail_job(job, error = RuntimeError.new("falhou"))
    job.ready_execution&.destroy!
    job.failed_with(error)
    job.reload
  end

  it "conta os jobs por fila e estado e a idade do pronto mais antigo" do
    enqueue(Channels::Email::IngestJob, "mailpit-1")
    travel 30.seconds
    enqueue(Channels::Email::IngestJob, "mailpit-2")
    enqueue(Channels::Email::IngestJob, "mailpit-3", wait: 5.minutes)
    claimed = enqueue(Conversations::MemoryRefreshJob, brand_id: infinitepay.id, contact_id: SecureRandom.uuid_v7,
                                                       conversation_id: SecureRandom.uuid_v7)
    claimed.ready_execution.destroy!
    process = SolidQueue::Process.register(kind: "Worker", pid: 1, hostname: "teste", name: "worker-teste")
    SolidQueue::ClaimedExecution.create!(job: claimed, process: process)
    travel 10.seconds

    reader.collect

    expect(value(:cloudesk_solid_queue_jobs, queue: "default", state: "ready")).to eq(2)
    expect(value(:cloudesk_solid_queue_jobs, queue: "default", state: "scheduled")).to eq(1)
    expect(value(:cloudesk_solid_queue_jobs, queue: "default", state: "claimed")).to eq(1)
    expect(value(:cloudesk_solid_queue_oldest_ready_age_seconds, queue: "default")).to be_within(0.5).of(40)
  end

  it "conta a fila de falhas por classe, com a idade da falha mais antiga" do
    fail_job(enqueue(Channels::Email::IngestJob, "mailpit-1"))
    travel 90.seconds
    fail_job(enqueue(Channels::Email::IngestJob, "mailpit-2"))
    fail_job(enqueue(Conversations::MemoryRefreshJob, brand_id: infinitepay.id, contact_id: SecureRandom.uuid_v7,
                                                      conversation_id: SecureRandom.uuid_v7))
    travel 30.seconds

    reader.collect

    expect(value(:cloudesk_solid_queue_failed_jobs, class: "Channels::Email::IngestJob")).to eq(2)
    expect(value(:cloudesk_solid_queue_failed_jobs, class: "Conversations::MemoryRefreshJob")).to eq(1)
    expect(value(:cloudesk_solid_queue_failed_oldest_age_seconds, class: "Channels::Email::IngestJob")).to be_within(0.5).of(120)
    expect(value(:cloudesk_solid_queue_failed_oldest_age_seconds, class: "Conversations::MemoryRefreshJob")).to be_within(0.5).of(30)
  end

  it "zera as séries que somem na coleta seguinte" do
    job = enqueue(Channels::Email::IngestJob, "mailpit-1")
    reader.collect
    expect(value(:cloudesk_solid_queue_jobs, queue: "default", state: "ready")).to eq(1)

    fail_job(job)
    reader.collect
    expect(value(:cloudesk_solid_queue_jobs, queue: "default", state: "ready")).to eq(0)
    expect(value(:cloudesk_solid_queue_oldest_ready_age_seconds, queue: "default")).to eq(0)
    expect(value(:cloudesk_solid_queue_failed_jobs, class: "Channels::Email::IngestJob")).to eq(1)

    SolidQueue::Job.delete_all
    reader.collect
    expect(value(:cloudesk_solid_queue_failed_jobs, class: "Channels::Email::IngestJob")).to eq(0)
  end
end

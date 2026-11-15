require "rails_helper"

RSpec.describe SmokeJob do
  it "usa o Solid Queue como adaptador" do
    expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::SolidQueueAdapter)
  end

  it "grava o job pela mesma conexão do app" do
    expect(SolidQueue::Record.connection_pool).to equal(ActiveRecord::Base.connection_pool)
  end

  it "é gravado nas tabelas do Solid Queue e executado pelo worker" do
    active_job = described_class.perform_later("f0")

    solid_job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
    expect(solid_job.ready_execution).to be_present

    expect_any_instance_of(described_class).to receive(:perform).with("f0").and_call_original

    claimed = SolidQueue::ReadyExecution.claim(solid_job.queue_name, 1, nil)
    expect(claimed.size).to eq(1)
    claimed.each(&:perform)

    expect(solid_job.reload.finished_at).to be_present
    expect(solid_job.failed_execution).to be_nil
  end
end

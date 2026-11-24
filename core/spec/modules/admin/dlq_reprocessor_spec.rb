require "rails_helper"

RSpec.describe Admin::DlqReprocessor do
  let(:brand) { infinitepay }
  let(:conversation) { Tenancy.with_brand(brand) { Conversation.create!(contact: Contact.first!, channel: "whatsapp") } }
  let(:jim_conversation) { Tenancy.with_brand(jim) { Conversation.create!(contact: Contact.first!, channel: "whatsapp") } }

  def reprocess(partition: 1, offset: 7)
    described_class.call(brand: brand, partition: partition, offset: offset, operator_name: "operator-a")
  end

  def reprocessed_events
    Tenancy.with_brand(brand) { AuditEvent.where(action: "dlq.reprocessed").order(:created_at, :id).to_a }
  end

  it "republica pelo Broker e grava dlq.reprocessed com origem, destino, diagnóstico e operador" do
    stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
    stub_dlq_reprocess(1, 7)

    result = nil
    expect { result = reprocess }.not_to(change { SolidQueue::Job.count })

    expect(result.value.fetch("destination")).to include("offset" => 40)
    event = reprocessed_events.sole
    expect(event).to have_attributes(actor_type: "operator", actor_id: nil, target_type: "Conversation",
                                     target_id: conversation.id, conversation_id: conversation.id)
    expect(event.payload.fetch("payload")).to eq(
      "source" => { "topic" => "agent.dlq", "partition" => 1, "offset" => 7 },
      "destination" => { "topic" => "agent.outbound", "partition" => 2, "offset" => 40 },
      "dlq_reason" => "core_rejected", "dlq_status" => "422", "dlq_failed_at" => "2026-11-23T14:00:00.000Z",
      "operator_name" => "operator-a"
    )
  end

  it "reprocessar de novo grava um segundo evento" do
    stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
    stub_dlq_reprocess(1, 7)

    2.times { reprocess }

    expect(reprocessed_events.size).to eq(2)
  end

  it "com erro do Broker na republicação, não grava nada" do
    stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
    stub_request(:post, dlq_url("/dlq/messages/1/7/reprocess")).to_return(status: 503, body: '{"error":"kafka_unavailable"}')

    expect { reprocess }.to raise_error(Admin::DlqClient::Error)
    expect(reprocessed_events).to be_empty
  end

  {
    "invalid_message" => ->(spec) { spec.dlq_listed_message(partition: 1, offset: 7, key: spec.conversation.id, reason: "invalid_message", status: nil) },
    "chave que não é conversa da marca" => ->(spec) { spec.dlq_listed_message(partition: 1, offset: 7, key: spec.jim_conversation.id) },
    "chave que não é UUID" => ->(spec) { spec.dlq_listed_message(partition: 1, offset: 7, key: "não-é-uuid") },
    "marca diferente" => ->(spec) { spec.dlq_listed_message(partition: 1, offset: 7, key: spec.conversation.id, brand: "jim") },
    "sem marca" => ->(spec) { spec.dlq_listed_message(partition: 1, offset: 7, key: spec.conversation.id, brand: nil) }
  }.each do |label, build|
    it "recusa #{label} com Admin::NotAllowed, sem chamar a republicação" do
      stub_dlq_list(brand, [ build.call(self) ])
      reprocess_stub = stub_dlq_reprocess(1, 7)

      expect { reprocess }.to raise_error(Admin::NotAllowed)
      expect(reprocess_stub).not_to have_been_requested
      expect(reprocessed_events).to be_empty
    end
  end

  it "recusa a mensagem fora da listagem da marca" do
    stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
    reprocess_stub = stub_dlq_reprocess(1, 8)

    expect { reprocess(offset: 8) }.to raise_error(Admin::NotAllowed, /não está na listagem/)
    expect(reprocess_stub).not_to have_been_requested
  end

  it "registra em log origem e destino quando a gravação falha depois do 200, e a exceção sobe" do
    stub_dlq_list(brand, [ dlq_listed_message(partition: 1, offset: 7, key: conversation.id) ])
    stub_dlq_reprocess(1, 7)
    allow(Audit::Command).to receive(:call).and_raise(ActiveRecord::StatementInvalid, "falha")
    allow(Rails.logger).to receive(:error)

    expect { reprocess }.to raise_error(ActiveRecord::StatementInvalid)
    expect(Rails.logger).to have_received(:error).with(include("dlq.reprocessed", "\"offset\":7", "\"offset\":40"))
  end
end

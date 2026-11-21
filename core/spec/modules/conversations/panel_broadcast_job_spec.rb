require "rails_helper"

RSpec.describe Conversations::PanelBroadcastJob do
  let(:conversation_id) { "01a1fa80-0000-7000-8000-000000000001" }
  let(:team_id) { "01a1fa80-0000-7000-8000-000000000002" }
  let(:refresh) { a_string_including('action="refresh"') }

  it "envia refresh ao stream da conversa e ao da equipe" do
    expect do
      described_class.perform_now(brand_id: infinitepay.id, conversation_id: conversation_id, team_id: team_id)
    end.to have_broadcasted_to("panel:conversation:#{conversation_id}").with(refresh)
      .and have_broadcasted_to("panel:team:#{team_id}").with(refresh)
  end

  it "sem equipe, envia só ao stream da conversa" do
    expect do
      described_class.perform_now(brand_id: infinitepay.id, conversation_id: conversation_id, team_id: nil)
    end.to have_broadcasted_to("panel:conversation:#{conversation_id}").with(refresh)
      .and have_broadcasted_to("panel:team:").exactly(0)
  end

  it "roda na fila channels, enfileirado na transação" do
    expect(described_class.queue_name).to eq("channels")
    expect(described_class.enqueue_after_transaction_commit).to be(false)
  end
end

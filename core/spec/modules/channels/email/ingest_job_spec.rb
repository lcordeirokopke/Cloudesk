require "rails_helper"

RSpec.describe Channels::Email::IngestJob do
  let(:mailpit) { "http://mailpit.test/api/v1" }

  def raw_email(from:, to:, message_id: "#{SecureRandom.hex(6)}@lojista.test", cc: nil)
    Mail.new do
      from from
      to to
      cc cc if cc
      subject "Repasse atrasado"
      message_id "<#{message_id}>"
      body "Meu repasse não caiu"
      content_type "text/plain; charset=UTF-8"
    end.to_s
  end

  def stub_raw(id, source)
    stub_request(:get, "#{mailpit}/message/#{id}/raw").to_return(status: 200, body: source)
  end

  def stub_tag(id, tag)
    stub_request(:put, "#{mailpit}/tags").with(body: { "IDs" => [ id ], "Tags" => [ tag ] }.to_json).to_return(status: 200, body: "ok")
  end

  def inbound_emails
    ActionMailbox::InboundEmail
  end

  it "e-mail para o suporte de uma marca vira InboundEmail e recebe a tag cloudesk-ingested" do
    stub_raw("m1", raw_email(from: "lojista@example.com", to: "suporte@infinitepay.test", message_id: "m1@lojista.test"))
    tag = stub_tag("m1", "cloudesk-ingested")

    expect { described_class.perform_now("m1") }.to change { inbound_emails.count }.by(1)

    expect(tag).to have_been_requested
    expect(inbound_emails.order(:id).last.message_id).to eq("m1@lojista.test")
    expect(jobs_of(ActionMailbox::RoutingJob).order(:id).last.queue_name).to eq("action_mailbox_routing")
  end

  it "aceita o e-mail de suporte em Cc" do
    stub_raw("m2", raw_email(from: "lojista@example.com", to: "outro@example.com", cc: "Payouts@JIM.test"))
    stub_tag("m2", "cloudesk-ingested")

    expect { described_class.perform_now("m2") }.to change { inbound_emails.count }.by(1)
  end

  it "a resposta do Core ao lojista recebe a tag cloudesk-ignored e não cria nada" do
    stub_raw("m3", raw_email(from: "suporte@infinitepay.test", to: "lojista@example.com"))
    tag = stub_tag("m3", "cloudesk-ignored")

    expect { described_class.perform_now("m3") }.not_to(change { inbound_emails.count })
    expect(tag).to have_been_requested
  end

  it "e-mail sem destinatário de suporte recebe a tag cloudesk-ignored" do
    stub_raw("m4", raw_email(from: "alguem@example.com", to: "outro@example.com"))
    tag = stub_tag("m4", "cloudesk-ignored")

    expect { described_class.perform_now("m4") }.not_to(change { inbound_emails.count })
    expect(tag).to have_been_requested
  end

  it "agenda nova tentativa quando o Mailpit não responde" do
    stub_request(:get, "#{mailpit}/message/m5/raw").to_return(status: 502)

    expect { described_class.perform_now("m5") }.to change { jobs_of(described_class).count }.by(1)
  end

  # Com commit de verdade: a criação repetida bate no índice único, e o PostgreSQL abortaria a
  # transação do RSpec. As tabelas do Action Mailbox e do Active Storage não têm RLS nem
  # append-only, e a limpeza apaga o que o exemplo gravou.
  describe "o mesmo e-mail duas vezes" do
    self.use_transactional_tests = false

    let(:message_id) { "repetido-#{SecureRandom.hex(6)}@lojista.test" }

    # Jobs gravados pelo exemplo: o roteamento do Action Mailbox e a análise do Active Storage.
    before { @last_job_id = SolidQueue::Job.maximum(:id).to_i }

    after do
      emails = inbound_emails.where(message_id: message_id)
      attachments = ActiveStorage::Attachment.where(record_type: "ActionMailbox::InboundEmail", record_id: emails.select(:id))
      blob_ids = attachments.pluck(:blob_id)
      attachments.delete_all
      emails.delete_all
      # create_and_extract_message_id! grava o blob antes do InboundEmail; na colisão, o blob fica sem anexo.
      orphan_blobs = ActiveStorage::Blob.where(filename: "message.eml").where.missing(:attachments)
                                        .where("active_storage_blobs.created_at > ?", 1.minute.ago).pluck(:id)
      ActiveStorage::Blob.where(id: blob_ids + orphan_blobs).delete_all
      SolidQueue::Job.where("id > ?", @last_job_id).destroy_all
    end

    it "cria um único InboundEmail" do
      source = raw_email(from: "lojista@example.com", to: "suporte@infinitepay.test", message_id: message_id)
      stub_raw("m6", source)
      stub_raw("m7", source)
      stub_tag("m6", "cloudesk-ingested")
      stub_tag("m7", "cloudesk-ingested")

      described_class.perform_now("m6")
      described_class.perform_now("m7")

      expect(inbound_emails.where(message_id: message_id).count).to eq(1)
    end
  end
end

require "rails_helper"

RSpec.describe Channels::DeliveryJob do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:phone) { identity_of(contact, "whatsapp") }
  let(:email) { identity_of(contact, "email") }
  let(:number) { brand_channel(brand, "whatsapp") }
  let(:support_email) { brand_channel(brand, "email") }
  let(:whatsapp_url) { "http://whatsapp.test/v1/#{number.value}/messages" }

  before { ActionMailer::Base.deliveries.clear }

  def receive_from(channel, **attributes)
    identity = { "whatsapp" => phone, "email" => email, "chat" => identity_of(contact, "chat") }.fetch(channel)
    Conversations::Intake.call(inbound_message(brand: brand, channel: channel, identity: identity, **attributes)).first
  end

  def reply(received, text: "Seu repasse cai hoje às 18h.")
    Tenancy.with_brand(brand) do
      conversation = Conversation.find(received.conversation.id)
      Conversations::Outbound.append!(conversation: conversation, author: "ai", text: text,
                                      in_reply_to_sequence: received.message.sequence)
    end
  end

  def delivery_job_for(message)
    jobs_of(described_class).order(:id).to_a.reverse.find { |job| job_arguments(job)["message_id"] == message.id }
  end

  def perform(message)
    described_class.perform_now(**job_arguments(delivery_job_for(message)).slice("brand_id", "message_id", "traceparent").symbolize_keys)
  end

  def delivered_event(message)
    Tenancy.with_brand(brand) { AuditEvent.find_by(action: "message.delivered", target_id: message.id) }
  end

  describe "Conversations::Outbound" do
    it "grava a mensagem no canal da mensagem respondida e enfileira a entrega na fila channels" do
      received = receive_from("whatsapp")
      message = reply(received)

      expect(message).to have_attributes(author: "ai", channel: "whatsapp", sequence: 2, brand_channel_id: number.id)
      job = delivery_job_for(message)
      expect(job.queue_name).to eq("channels")
      expect(job_arguments(job)).to include("brand_id" => brand.id, "message_id" => message.id)

      event = Tenancy.with_brand(brand) { AuditEvent.find_by!(action: "message.created", target_id: message.id) }
      expect(event.actor_type).to eq("ai")
      expect(event.payload["payload"]).to include("in_reply_to_sequence" => 1,
                                                  "message" => { "author" => "ai", "channel" => "whatsapp", "text" => message.body })
    end

    it "não enfileira o webhook ao Broker" do
      received = receive_from("whatsapp")

      expect { reply(received) }.not_to(change { webhook_jobs.count })
    end

    it "não deixa mensagem nem job quando a gravação falha" do
      received = receive_from("whatsapp")
      allow(AuditEvent).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)

      expect { reply(received) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(jobs_of(described_class).count { |job| job_arguments(job)["brand_id"] == brand.id }).to eq(0)
      Tenancy.with_brand(brand) { expect(Message.where(conversation_id: received.conversation.id).count).to eq(1) }
    end

    it "recusa o autor customer" do
      received = receive_from("whatsapp")

      expect do
        Conversations::Outbound.append!(conversation: received.conversation, author: "customer", text: "x", in_reply_to_sequence: 1)
      end.to raise_error(ArgumentError)
    end
  end

  describe "WhatsApp" do
    it "faz o POST da Cloud API pelo número que recebeu a mensagem e grava message.delivered" do
      message = reply(receive_from("whatsapp"))
      request = stub_request(:post, whatsapp_url).with(
        headers: {
          "Authorization" => "Bearer #{ENV.fetch('WHATSAPP_ACCESS_TOKEN')}",
          "Content-Type" => "application/json",
          "X-Cloudesk-Message-Id" => message.id
        },
        body: {
          messaging_product: "whatsapp", recipient_type: "individual", to: phone.delete_prefix("+"),
          type: "text", text: { body: "Seu repasse cai hoje às 18h." }
        }.to_json
      ).to_return(status: 200, body: { messaging_product: "whatsapp", messages: [ { id: "wamid.saida" } ] }.to_json)

      perform(message)

      expect(request).to have_been_requested.once
      expect(WebMock).to have_requested(:post, whatsapp_url).with { |req| TraceContext.parse(req.headers["Traceparent"]).present? }
      event = delivered_event(message)
      expect(event).to have_attributes(actor_type: "system", target_type: "Message", conversation_id: message.conversation_id)
      expect(event.payload["payload"]).to include("channel" => "whatsapp")
      expect(Time.iso8601(event.payload["payload"]["delivered_at"])).to be_within(5.seconds).of(Time.current)
    end

    it "agenda nova tentativa em 5xx, sem message.delivered" do
      message = reply(receive_from("whatsapp"))
      stub_request(:post, whatsapp_url).to_return(status: 503)

      expect { perform(message) }.to change { jobs_of(described_class).where.not(scheduled_at: nil).where("scheduled_at > ?", Time.current).count }.by(1)
      expect(delivered_event(message)).to be_nil
    end

    it "agenda nova tentativa em erro de rede" do
      message = reply(receive_from("whatsapp"))
      stub_request(:post, whatsapp_url).to_raise(Errno::ECONNREFUSED)

      expect { perform(message) }.to change { jobs_of(described_class).count }.by(1)
      expect(delivered_event(message)).to be_nil
    end

    it "falha sem nova tentativa em 4xx" do
      message = reply(receive_from("whatsapp"))
      stub_request(:post, whatsapp_url).to_return(status: 400, body: "inválido")

      expect { perform(message) }.to raise_error(Channels::DeliveryError::Permanent)
      expect(delivered_event(message)).to be_nil
    end
  end

  describe "e-mail" do
    it "responde pelo e-mail de suporte que recebeu, na thread do último e-mail do lojista" do
      receive_from("email", subject: "Repasse atrasado", external_id: "primeiro@lojista.test")
      received = receive_from("email", subject: "Re: Repasse atrasado", external_id: "segundo@lojista.test")
      message = reply(received)

      perform(message)

      delivered = ActionMailer::Base.deliveries.sole
      expect(delivered.from).to eq([ support_email.value ])
      expect(delivered.to).to eq([ email ])
      expect(delivered.subject).to eq("Re: Repasse atrasado")
      expect(delivered.in_reply_to).to eq("segundo@lojista.test")
      expect(delivered.references).to eq("segundo@lojista.test")
      expect(delivered["X-Cloudesk-Message-Id"].value).to eq(message.id)
      expect(delivered.body.to_s).to include("Seu repasse cai hoje às 18h.")
      expect(delivered_event(message).payload["payload"]).to include("channel" => "email")
    end

    it "acrescenta Re: ao assunto sem o prefixo" do
      message = reply(receive_from("email", subject: "Taxas", external_id: "taxas@lojista.test"))

      perform(message)

      expect(ActionMailer::Base.deliveries.sole.subject).to eq("Re: Taxas")
    end
  end

  describe "chat" do
    it "acrescenta a mensagem no stream Turbo do lojista" do
      message = reply(receive_from("chat"))
      stream = Turbo::StreamsChannel.send(:stream_name_from, Channels::Chat.streamables(contact))

      expect { perform(message) }.to have_broadcasted_to(stream).with { |data|
        expect(data).to include("turbo-stream", 'action="append"', 'target="messages"', "message_#{message.id}", message.body)
      }
      expect(delivered_event(message).payload["payload"]).to include("channel" => "chat")
    end
  end

  it "responde no canal da mensagem respondida quando a conversa tem mensagens de dois canais" do
    by_whatsapp = receive_from("whatsapp", text: "Pelo WhatsApp")
    by_email = receive_from("email", text: "Pelo e-mail", subject: "Assunto", external_id: "dois@lojista.test")
    expect(by_email.conversation.id).to eq(by_whatsapp.conversation.id)
    stub_request(:post, whatsapp_url).to_return(status: 200, body: "{}")

    to_whatsapp = reply(by_whatsapp, text: "Resposta no WhatsApp")
    to_email = reply(by_email, text: "Resposta no e-mail")
    perform(to_whatsapp)
    perform(to_email)

    expect(to_whatsapp.channel).to eq("whatsapp")
    expect(to_email.channel).to eq("email")
    expect(WebMock).to have_requested(:post, whatsapp_url).once
    expect(ActionMailer::Base.deliveries.sole.body.to_s).to include("Resposta no e-mail")
  end
end

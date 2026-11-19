require "rails_helper"

RSpec.describe Conversations::Intake do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:phone) { identity_of(contact, "whatsapp") }

  def whatsapp_message(**attributes)
    inbound_message(brand: brand, channel: "whatsapp", identity: phone, **attributes)
  end

  def intake(inbound)
    described_class.call(inbound).first
  end

  def actions_of(conversation_id)
    audit_events_of(brand, conversation_id).map(&:action)
  end

  def counts
    Tenancy.with_brand(brand) do
      { messages: Message.count, audit_events: AuditEvent.count, contacts: Contact.count,
        conversations: Conversation.count, jobs: webhook_jobs.count }
    end
  end

  def resolve(conversation, resolved_at)
    Tenancy.with_brand(brand) do
      conversation = Conversation.find(conversation.id)
      conversation.transition_to!("with_ai")
      conversation.transition_to!("resolved")
      conversation.update!(resolved_at: resolved_at)
    end
  end

  describe "abertura de conversa" do
    it "abre a conversa no canal da mensagem e grava a mensagem com sequência 1" do
      result = intake(whatsapp_message)

      expect(result.duplicate).to be(false)
      expect(result.contact.id).to eq(contact.id)
      expect(result.conversation).to have_attributes(state: "triage", channel: "whatsapp", contact_id: contact.id)
      expect(result.message).to have_attributes(sequence: 1, author: "customer", channel: "whatsapp",
                                                body: "Meu repasse de ontem não caiu",
                                                brand_channel_id: brand_channel(brand, "whatsapp").id)
      expect(actions_of(result.conversation.id)).to eq(%w[conversation.opened message.created])
    end

    it "usa a conversa aberta do lojista nas mensagens seguintes" do
      first = intake(whatsapp_message)
      second = intake(whatsapp_message(text: "Alguma novidade?"))

      expect(second.conversation.id).to eq(first.conversation.id)
      expect(second.message.sequence).to eq(2)
      expect(actions_of(first.conversation.id)).to eq(%w[conversation.opened message.created message.created])
    end

    it "reabre a conversa resolvida dentro do prazo de reabertura" do
      first = intake(whatsapp_message)
      resolve(first.conversation, 1.hour.ago)

      second = intake(whatsapp_message(text: "Voltou a acontecer"))

      expect(second.conversation.id).to eq(first.conversation.id)
      expect(second.conversation.state).to eq("triage")
      reopened = audit_events_of(brand, first.conversation.id).find { |event| event.action == "conversation.reopened" }
      expect(reopened).to have_attributes(actor_type: "system", before: { "state" => "resolved" }, after: { "state" => "triage" })
    end

    it "fecha a conversa resolvida com prazo vencido e abre outra" do
      first = intake(whatsapp_message)
      resolve(first.conversation, (brand.reopen_window_minutes + 1).minutes.ago)

      second = intake(whatsapp_message(text: "Outro assunto"))

      expect(second.conversation.id).not_to eq(first.conversation.id)
      expect(second.message.sequence).to eq(1)
      Tenancy.with_brand(brand) { expect(Conversation.find(first.conversation.id).state).to eq("closed") }
      expect(actions_of(first.conversation.id).last).to eq("conversation.closed")
      expect(actions_of(second.conversation.id)).to eq(%w[conversation.opened message.created])
    end
  end

  describe "mensagem repetida" do
    it "o mesmo external_id no mesmo canal não cria mensagem, audit_event nem job" do
      inbound = whatsapp_message(external_id: "wamid.repetido")
      first = intake(inbound)
      before_counts = counts

      second = intake(inbound)

      expect(second.duplicate).to be(true)
      expect(second.message.id).to eq(first.message.id)
      expect(counts).to eq(before_counts)
    end

    it "texto igual com external_id diferente é mensagem nova" do
      first = intake(whatsapp_message(text: "oi"))
      second = intake(whatsapp_message(text: "oi"))

      expect(second.duplicate).to be(false)
      expect(second.message.sequence).to eq(first.message.sequence + 1)
    end
  end

  describe "identidade" do
    it "lojista desconhecido gera Contact com uma identidade e contact.created" do
      before_counts = counts

      result = intake(inbound_message(brand: brand, channel: "whatsapp", identity: "+5511900000001", contact_name: "Lojista Novo"))

      expect(counts[:contacts]).to eq(before_counts[:contacts] + 1)
      Tenancy.with_brand(brand) do
        created = Contact.find(result.contact.id)
        expect(created).to have_attributes(name: "Lojista Novo", locale: "pt-BR")
        expect(created.identities.pluck(:channel, :value)).to eq([ %w[whatsapp +5511900000001] ])
        event = AuditEvent.find_by!(action: "contact.created", target_id: created.id)
        expect(event).to have_attributes(actor_type: "system", target_type: "Contact")
      end
    end

    it "usa a identidade como nome quando o canal não informa o nome" do
      result = intake(inbound_message(brand: brand, channel: "chat", identity: "app-desconhecido"))

      Tenancy.with_brand(brand) { expect(Contact.find(result.contact.id).name).to eq("app-desconhecido") }
    end

    it "o mesmo lojista em WhatsApp e e-mail é um único Contact, com uma conversa e as duas mensagens" do
      email = identity_of(contact, "email")

      by_whatsapp = intake(whatsapp_message(text: "Pelo WhatsApp"))
      by_email = intake(inbound_message(brand: brand, channel: "email", identity: email, text: "Pelo e-mail", subject: "Repasse"))

      expect(by_email.contact.id).to eq(contact.id)
      expect(by_email.conversation.id).to eq(by_whatsapp.conversation.id)
      Tenancy.with_brand(brand) do
        messages = Message.where(conversation_id: by_whatsapp.conversation.id).order(:sequence)
        expect(messages.pluck(:sequence, :channel, :body)).to eq([ [ 1, "whatsapp", "Pelo WhatsApp" ], [ 2, "email", "Pelo e-mail" ] ])
      end
    end

    it "a mesma identidade em outra marca é outro lojista" do
      result = described_class.call(inbound_message(brand: jim, channel: "whatsapp", identity: phone)).first

      expect(result.contact.brand_id).to eq(jim.id)
      expect(result.contact.id).not_to eq(contact.id)
    end
  end

  describe "message.created" do
    it "grava o payload do contrato e os dados da entrada, e enfileira o job de webhook" do
      before_jobs = webhook_jobs.count
      result = intake(whatsapp_message(external_id: "wamid.payload",
                                       attachments: [ { kind: "image", content_type: "image/jpeg" } ]))

      event = audit_events_of(brand, result.conversation.id).find { |audit_event| audit_event.action == "message.created" }
      expect(event).to have_attributes(actor_type: "customer", actor_id: contact.id, target_id: result.message.id)
      expect(event.payload.fetch("payload")).to eq(
        "message" => { "author" => "customer", "channel" => "whatsapp", "text" => "Meu repasse de ontem não caiu" },
        "external_id" => "wamid.payload",
        "attachments" => [ { "kind" => "image", "content_type" => "image/jpeg" } ],
        "identity" => phone
      )
      expect(Contract::MessageCreated.build(event.payload)).to include("sequence" => 1, "brand" => "infinitepay")

      expect(webhook_jobs.count).to eq(before_jobs + 1)
      expect(job_arguments(webhook_jobs.order(:id).last)).to include("event_id" => event.event_id)
    end

    it "só a mensagem do lojista enfileira o webhook; abertura e reabertura não" do
      before_jobs = webhook_jobs.count

      intake(whatsapp_message)

      expect(webhook_jobs.count).to eq(before_jobs + 1)
    end

    it "mensagem só com anexo recebe o texto padrão no locale da marca" do
      ip = intake(whatsapp_message(text: "", attachments: [ { kind: "image" } ]))
      jim_contact = seed_contact(jim)
      us = described_class.call(
        inbound_message(brand: jim, channel: "whatsapp", identity: identity_of(jim_contact, "whatsapp"),
                        text: nil, attachments: [ { kind: "document", filename: "extrato.pdf" } ])
      ).first

      expect(ip.message.body).to eq("[imagem enviada]")
      expect(ip.message.attachments).to eq([ { "kind" => "image" } ])
      expect(us.message.body).to eq("[document sent]")
    end

    it "grava received_at da entrada e um único trace para os eventos da mensagem" do
      received_at = Time.utc(2026, 11, 19, 12, 0, 0.123r)
      result = intake(whatsapp_message(received_at: received_at))

      events = audit_events_of(brand, result.conversation.id)
      expect(events.map { |event| event.payload["received_at"] }.uniq).to eq([ "2026-11-19T12:00:00.123Z" ])
      expect(events.map(&:trace_id).uniq.size).to eq(1)
    end
  end

  it "recusa mensagens de marcas diferentes na mesma chamada" do
    expect do
      described_class.call([ whatsapp_message, inbound_message(brand: jim, channel: "chat", identity: "app-x") ])
    end.to raise_error(ArgumentError)
  end

  # As duas threads gravam com commit de verdade, fora da transação do RSpec. audit_events é
  # append-only; a limpeza roda com o papel dono, que desliga o trigger de audit_events só durante a
  # limpeza, na mesma transação.
  describe "primeiras mensagens simultâneas do mesmo lojista novo" do
    self.use_transactional_tests = false

    let(:new_identity) { "+5511988#{rand(100_000..999_999)}" }

    after do
      contact_ids = Tenancy.with_brand(brand) do
        ContactIdentity.where(channel: "whatsapp", value: new_identity).pluck(:contact_id)
      end
      cleanup(contact_ids)
    end

    def cleanup(contact_ids)
      return if contact_ids.empty?

      connection = OwnerRecord.lease_connection
      ids = contact_ids.map { |id| connection.quote(id) }.join(", ")
      OwnerRecord.transaction do
        connection.execute("SELECT set_config('app.brand_id', #{connection.quote(brand.id)}, true)")
        conversations = "SELECT id FROM conversations WHERE contact_id IN (#{ids})"
        event_ids = connection.select_values("SELECT event_id FROM audit_events WHERE conversation_id IN (#{conversations}) OR target_id IN (#{ids})")
        connection.execute("ALTER TABLE audit_events DISABLE TRIGGER audit_events_block_row_changes")
        connection.execute("DELETE FROM audit_events WHERE conversation_id IN (#{conversations}) OR target_id IN (#{ids})")
        connection.execute("ALTER TABLE audit_events ENABLE TRIGGER audit_events_block_row_changes")
        connection.execute("DELETE FROM messages WHERE conversation_id IN (#{conversations})")
        connection.execute("DELETE FROM conversations WHERE contact_id IN (#{ids})")
        connection.execute("DELETE FROM contact_identities WHERE contact_id IN (#{ids})")
        connection.execute("DELETE FROM contacts WHERE id IN (#{ids})")
        event_ids.each do |event_id|
          SolidQueue::Job.where(class_name: "Agents::WebhookDeliveryJob").where("arguments LIKE ?", "%#{event_id}%").destroy_all
        end
      end
    end

    it "gera um Contact, uma conversa e as sequências 1 e 2" do
      # As duas threads passam pela busca da identidade antes de qualquer uma gravar: as duas tentam
      # criar o lojista, e a que perde no índice único tenta de novo.
      barrier = Concurrent::CyclicBarrier.new(2)
      allow(ContactIdentity).to receive(:find_by).and_wrap_original do |original, *arguments, **options|
        found = original.call(*arguments, **options)
        unless Thread.current[:intake_barrier_passed]
          Thread.current[:intake_barrier_passed] = true
          barrier.wait(5)
        end
        found
      end

      threads = 2.times.map do |index|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            described_class.call(
              inbound_message(brand: brand, channel: "whatsapp", identity: new_identity, text: "simultânea #{index}")
            ).first.message.sequence
          end
        end
      end
      sequences = threads.map(&:value)

      expect(sequences.sort).to eq([ 1, 2 ])
      # Duas buscas da primeira tentativa e a da nova tentativa da thread que perdeu.
      expect(ContactIdentity).to have_received(:find_by).exactly(3).times
      Tenancy.with_brand(brand) do
        identities = ContactIdentity.where(channel: "whatsapp", value: new_identity)
        expect(identities.count).to eq(1)
        conversations = Conversation.where(contact_id: identities.first.contact_id)
        expect(conversations.count).to eq(1)
        expect(Message.where(conversation_id: conversations.first.id).order(:sequence).pluck(:sequence)).to eq([ 1, 2 ])
      end
    end
  end
end

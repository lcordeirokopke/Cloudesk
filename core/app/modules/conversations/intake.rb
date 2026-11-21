module Conversations
  # Caminho único de entrada das mensagens do lojista, comum aos três canais. Em uma transação, na
  # marca das mensagens, para cada Channels::InboundMessage:
  #   1. external_id já gravado na marca e no canal: é reenvio; devolve a mensagem existente, sem
  #      novo efeito;
  #   2. busca o lojista pela identidade; sem identidade, cria Contact e ContactIdentity
  #      (contact.created);
  #   3. busca a conversa não closed do lojista com FOR UPDATE:
  #        nenhuma: abre (conversation.opened);
  #        resolved dentro do prazo de reabertura: resolved -> triage (conversation.reopened) e,
  #          na mesma transação, recálculo da memória do lojista (Conversations::MemoryRefresh),
  #          que tira dela a conversa reaberta;
  #        resolved com prazo vencido: resolved -> closed (conversation.closed) e abre outra;
  #        qualquer outro estado: usa a conversa;
  #   4. conversa em triage (aberta ou reaberta): classifica e roteia (Routing::Route) pelo texto da
  #      mensagem e, no e-mail, pelo assunto;
  #   5. grava a mensagem com a próxima sequência (message.created). O job de webhook ao Broker é
  #      enfileirado só quando a conversa está em with_ai, e o painel do analista é atualizado só
  #      com a conversa em awaiting_human ou with_human.
  #
  # Duas primeiras mensagens simultâneas do mesmo lojista batem nos índices únicos (identidade,
  # conversa aberta por lojista, external_id). A transação que perde é desfeita inteira e tentada de
  # novo, e na nova tentativa encontra o que a outra criou. A nova tentativa fica fora do
  # Tenancy.with_brand: no PostgreSQL, a transação com erro fica abortada.
  class Intake
    MAX_ATTEMPTS = 3

    # message:   Message gravada, ou a existente no reenvio.
    # duplicate: true quando a mensagem é reenvio.
    Result = Data.define(:message, :conversation, :contact, :duplicate)

    # inbound_messages: uma ou mais Channels::InboundMessage da mesma marca. Devolve um Result por
    # mensagem, na ordem recebida.
    def self.call(inbound_messages)
      new(Array(inbound_messages)).call
    end

    def initialize(inbound_messages)
      raise ArgumentError, "nenhuma mensagem informada" if inbound_messages.empty?

      brands = inbound_messages.map { |inbound| inbound.brand.id }.uniq
      raise ArgumentError, "as mensagens devem ser da mesma marca" if brands.size > 1

      @inbound_messages = inbound_messages
      @brand = inbound_messages.first.brand
    end

    def call
      attempts = 0
      begin
        attempts += 1
        Current.set(traceparent: Current.traceparent || TraceContext.generate) do
          Tenancy.with_brand(@brand) { @inbound_messages.map { |inbound| intake(inbound) } }
        end
      rescue ActiveRecord::RecordNotUnique
        raise if attempts >= MAX_ATTEMPTS

        retry
      end
    end

    private

    def intake(inbound)
      Current.set(received_at: inbound.received_at) do
        existing = find_existing(inbound)
        next Result.new(message: existing, conversation: existing.conversation, contact: existing.conversation.contact, duplicate: true) if existing

        contact = find_or_create_contact(inbound)
        conversation = current_conversation(contact, inbound)
        route(conversation, inbound) if conversation.state == "triage"
        message = append_message(conversation, contact, inbound)
        Result.new(message: message, conversation: conversation, contact: contact, duplicate: false)
      end
    end

    def find_existing(inbound)
      return nil if inbound.external_id.nil?

      Message.find_by(brand_id: @brand.id, channel: inbound.channel, external_id: inbound.external_id)
    end

    def find_or_create_contact(inbound)
      identity = ContactIdentity.find_by(channel: inbound.channel, value: inbound.identity)
      return identity.contact if identity

      name = inbound.contact_name.presence || inbound.identity
      Audit::Command.call(brand: @brand, type: "contact.created", actor_type: "system") do |change|
        contact = Contact.create!(name: name, locale: @brand.locale)
        contact.identities.create!(channel: inbound.channel, value: inbound.identity)
        change.target = contact
        change.after = { name: name, identity: { channel: inbound.channel, value: inbound.identity } }
        contact
      end.value
    end

    def current_conversation(contact, inbound)
      conversation = Conversation.where(contact_id: contact.id).where.not(state: "closed").lock.first
      return open_conversation(contact, inbound) if conversation.nil?
      return conversation unless conversation.state == "resolved"

      if reopen_window_expired?(conversation, inbound)
        close_conversation(conversation)
        open_conversation(contact, inbound)
      else
        reopen_conversation(conversation)
      end
    end

    def reopen_window_expired?(conversation, inbound)
      conversation.resolved_at.present? && conversation.resolved_at < inbound.received_at - @brand.reopen_window
    end

    def open_conversation(contact, inbound)
      Audit::Command.call(brand: @brand, type: "conversation.opened", actor_type: "system") do |change|
        conversation = Conversation.create!(contact: contact, channel: inbound.channel)
        change.target = conversation
        change.conversation = conversation
        change.after = { state: conversation.state, channel: conversation.channel }
        conversation
      end.value
    end

    def reopen_conversation(conversation)
      transition(conversation, "conversation.reopened", "triage", "lojista escreveu dentro do prazo de reabertura")
      MemoryRefresh.call(brand: @brand, contact_id: conversation.contact_id, conversation: conversation)
      conversation
    end

    def close_conversation(conversation)
      transition(conversation, "conversation.closed", "closed", "prazo de reabertura vencido")
    end

    def transition(conversation, type, new_state, reason)
      Audit::Command.call(brand: @brand, type: type, actor_type: "system", reason: reason) do |change|
        change.before = { state: conversation.state }
        conversation.transition_to!(new_state)
        change.after = { state: conversation.state }
        change.target = conversation
        change.conversation = conversation
        conversation
      end.value
    end

    def route(conversation, inbound)
      Routing::Route.call(
        conversation: conversation, trigger: "intake", text: inbound.text, subject: inbound.subject,
        received_at: inbound.received_at
      )
    end

    # O payload.message segue o formato do contrato (author, channel, text), lido por
    # Contract::MessageCreated.build. Os demais campos ficam só no audit_event: identity é o
    # destinatário da resposta, e subject e external_id formam o assunto e o In-Reply-To do e-mail.
    def append_message(conversation, contact, inbound)
      body = inbound.text.presence || Channels::AttachmentText.for(@brand, inbound.attachments.first&.fetch("kind", nil))

      Audit::Command.call(brand: @brand, type: "message.created", actor_type: "customer", actor_id: contact.id,
                          webhook: conversation.state == "with_ai",
                          panel: Conversation::HUMAN_STATES.include?(conversation.state)) do |change|
        message = conversation.append_message!(
          channel: inbound.channel, author: "customer", body: body, external_id: inbound.external_id,
          attachments: inbound.attachments, brand_channel_id: inbound.brand_channel&.id
        )
        change.target = message
        change.conversation = conversation
        change.sequence = message.sequence
        change.payload = {
          message: { author: "customer", channel: inbound.channel, text: body },
          external_id: inbound.external_id,
          attachments: inbound.attachments,
          identity: inbound.identity,
          subject: inbound.subject
        }.compact
        message
      end.value
    end
  end
end

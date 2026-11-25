module Conversations
  # Recalcula do zero a memória do lojista (CustomerMemory) a partir das conversas encerradas dele.
  # Roda dentro do Tenancy.with_brand de quem chama (o Intake na reabertura, o MemoryRefreshJob na
  # resolução):
  #   1. trava o lojista (FOR UPDATE), depois da conversa, que quem chama já tem travada: serializa os recálculos do mesmo lojista e evita a
  #      corrida no índice único (brand_id, contact_id);
  #   2. lê as até CustomerMemory::MAX_ENTRIES conversas resolved ou closed do lojista, por
  #      resolved_at decrescente, e monta entries e summary (uma linha por conversa, no locale do
  #      lojista);
  #   3. sem conversa encerrada: apaga a memória que existe (customer_memory.deleted);
  #      summary e entries iguais aos gravados: nada é gravado;
  #      senão: cria ou atualiza (customer_memory.updated).
  # Os eventos têm ator system, alvo a CustomerMemory, a conversa que disparou o recálculo e before e
  # after com summary e entries. A conversa em outro estado (inclusive a reaberta, em triage) fica
  # fora da memória.
  #
  # resolved_by é analyst quando o atendente da conversa é humano e ai nos demais casos: o atendente
  # fica na conversa ao resolver, nos dois caminhos de resolução.
  module MemoryRefresh
    CLOSED_STATES = %w[resolved closed].freeze

    module_function

    # Devolve a CustomerMemory gravada ou existente, ou nil quando o lojista fica sem memória.
    def call(brand:, contact_id:, conversation:)
      Tenancy.with_brand(brand) do
        contact = Contact.lock.find(contact_id)
        memory = CustomerMemory.find_or_initialize_by(contact_id: contact.id)
        entries = entries_for(contact)

        if entries.empty?
          delete(brand, memory, conversation) if memory.persisted?
          nil
        else
          summary = I18n.with_locale(contact.locale) { entries.map { |entry| line(entry) }.join("\n") }
          unchanged = memory.persisted? && memory.summary == summary && memory.entries == entries
          unchanged ? memory : save(brand, memory, conversation, summary, entries)
        end
      end
    end

    def entries_for(contact)
      conversations = Conversation.includes(:attendant).where(contact_id: contact.id, state: CLOSED_STATES)
                                  .order(Conversation.arel_table[:resolved_at].desc.nulls_last, id: :desc)
                                  .limit(CustomerMemory::MAX_ENTRIES).to_a
      return [] if conversations.empty?

      ids = conversations.map(&:id)
      first_messages = Message.where(conversation_id: ids, author: "customer")
                              .select("DISTINCT ON (conversation_id) conversation_id, body")
                              .order(:conversation_id, :sequence).to_h { |message| [ message.conversation_id, message.body ] }
      handoff_reasons = Handoff.where(conversation_id: ids)
                               .select("DISTINCT ON (conversation_id) conversation_id, reason")
                               .order(:conversation_id, created_at: :desc, id: :desc)
                               .to_h { |handoff| [ handoff.conversation_id, handoff.reason ] }

      conversations.map do |conversation|
        {
          "category" => conversation.category,
          "channel" => conversation.channel,
          "resolved_by" => conversation.attendant&.kind == "human" ? "analyst" : "ai",
          "resolved_at" => conversation.resolved_at&.utc&.iso8601(3),
          "handoff_reason" => handoff_reasons[conversation.id],
          "first_message" => first_messages[conversation.id].to_s.squish.truncate(CustomerMemory::FIRST_MESSAGE_LIMIT)
        }
      end
    end

    def line(entry)
      handoff = entry["handoff_reason"] ? I18n.t("conversations.memory.handoff", reason: entry["handoff_reason"]) : ""
      I18n.t(
        "conversations.memory.line",
        date: Time.iso8601(entry["resolved_at"]).utc.strftime(I18n.t("conversations.memory.date_format")),
        channel: I18n.t("conversations.memory.channels.#{entry['channel']}"),
        category: entry["category"] || I18n.t("conversations.memory.no_category"),
        resolved_by: I18n.t("conversations.memory.resolved_by.#{entry['resolved_by']}"),
        handoff: handoff,
        first_message: entry["first_message"]
      )
    end

    def save(brand, memory, conversation, summary, entries)
      Audit::Command.call(brand: brand, type: "customer_memory.updated", actor_type: "system") do |change|
        change.before = snapshot(memory) if memory.persisted?
        memory.update!(summary: summary, entries: entries)
        change.after = snapshot(memory)
        change.target = memory
        change.conversation = conversation
        memory
      end.value
    end

    def delete(brand, memory, conversation)
      Audit::Command.call(brand: brand, type: "customer_memory.deleted", actor_type: "system") do |change|
        change.before = snapshot(memory)
        memory.destroy!
        change.target = memory
        change.conversation = conversation
        memory
      end
    end

    def snapshot(memory)
      { summary: memory.summary, entries: memory.entries }
    end
  end
end

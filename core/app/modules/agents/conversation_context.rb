module Agents
  # Corpo da resposta ao GET da context_url (schema context de contracts/v1): a conversa, o histórico
  # completo em ordem crescente de sequence e a memória do lojista (CustomerMemory): summary,
  # updated_at e conversations (as entries, na ordem gravada), ou null quando o lojista não tem
  # memória.
  # Roda dentro do Tenancy.with_brand da marca da conversa; a conversa de outra marca não é visível e
  # lança ActiveRecord::RecordNotFound.
  module ConversationContext
    module_function

    def call(conversation_id)
      conversation = Conversation.find(conversation_id)
      brand = Brand.find(conversation.brand_id)
      messages = Message.where(conversation_id: conversation.id).order(:sequence)
                        .pluck(:sequence, :author, :channel, :body, :created_at)

      {
        "conversation" => {
          "id" => conversation.id,
          "brand" => brand.slug,
          "channel" => conversation.channel,
          "state" => conversation.state,
          "last_sequence" => conversation.last_sequence
        },
        "messages" => messages.map do |sequence, author, channel, body, created_at|
          {
            "sequence" => sequence, "author" => author, "channel" => channel, "text" => body,
            "created_at" => created_at.utc.iso8601(3)
          }
        end,
        "customer_memory" => customer_memory(conversation.contact_id)
      }
    end

    def customer_memory(contact_id)
      memory = CustomerMemory.find_by(contact_id: contact_id)
      return nil if memory.nil?

      { "summary" => memory.summary, "updated_at" => memory.updated_at.utc.iso8601(3), "conversations" => memory.entries }
    end
  end
end

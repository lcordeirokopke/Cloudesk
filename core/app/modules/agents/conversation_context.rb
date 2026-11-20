module Agents
  # Corpo da resposta ao GET da context_url (schema context de contracts/v1): a conversa, o histórico
  # completo em ordem crescente de sequence e a memória do lojista, null nesta versão.
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
        "customer_memory" => nil
      }
    end
  end
end

module Conversations
  # Recalcula a memória do lojista depois de um conversation.resolved, do agente ou do analista.
  # É enfileirado na mesma transação da resolução (outbox); por isso enqueue_after_transaction_commit
  # fica desligado. Na marca do job, chama Conversations::MemoryRefresh com a conversa que disparou o
  # recálculo. O cálculo lê o estado atual: a repetição do job, ou um job que roda depois de uma
  # reabertura, chega ao mesmo resultado e não grava nada.
  class MemoryRefreshJob < ApplicationJob
    queue_as :default

    self.enqueue_after_transaction_commit = false

    def perform(brand_id:, contact_id:, conversation_id:)
      brand = Brand.find(brand_id)
      Tenancy.with_brand(brand) do
        conversation = Conversation.find_by(id: conversation_id)
        MemoryRefresh.call(brand: brand, contact_id: contact_id, conversation: conversation)
      end
    end
  end
end

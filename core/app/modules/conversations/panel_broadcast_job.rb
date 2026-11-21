module Conversations
  # Atualiza as telas do painel do analista depois de uma mudança gravada com panel: true no
  # Audit::Command. É enfileirado na mesma transação da mudança (outbox); por isso
  # enqueue_after_transaction_commit fica desligado. Envia um Turbo Stream refresh ao stream da
  # conversa e, quando a conversa está em uma fila com equipe, ao stream da equipe. Não lê o
  # domínio: a página recarregada lê o estado confirmado.
  class PanelBroadcastJob < ApplicationJob
    queue_as :channels

    self.enqueue_after_transaction_commit = false

    def perform(brand_id:, conversation_id:, team_id:)
      Turbo::StreamsChannel.broadcast_refresh_to(PanelBroadcast.conversation_stream(conversation_id))
      Turbo::StreamsChannel.broadcast_refresh_to(PanelBroadcast.team_stream(team_id)) if team_id
    end
  end
end

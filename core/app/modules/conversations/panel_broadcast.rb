module Conversations
  # Streams Turbo do painel do analista: um por equipe (fila de escalas e conversas da equipe) e um
  # por conversa (tela da conversa). As páginas assinam o stream com turbo_stream_from e recebem um
  # refresh, que recarrega a página com morph.
  module PanelBroadcast
    module_function

    def team_stream(team_id)
      "panel:team:#{team_id}"
    end

    def conversation_stream(conversation_id)
      "panel:conversation:#{conversation_id}"
    end
  end
end

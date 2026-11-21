module Panel
  # POST /panel/conversations/:conversation_id/replies: resposta do analista ao lojista, pelo canal
  # da última mensagem do lojista (Conversations::AnalystActions.reply!).
  class RepliesController < BaseController
    def create
      Conversations::AnalystActions.reply!(analyst: current_analyst, conversation_id: params[:conversation_id],
                                           text: params[:text])
      redirect_to panel_conversation_path(params[:conversation_id]), status: :see_other
    rescue Conversations::AnalystActions::NotAllowed => error
      redirect_to panel_conversation_path(params[:conversation_id]), alert: error.message, status: :see_other
    end
  end
end

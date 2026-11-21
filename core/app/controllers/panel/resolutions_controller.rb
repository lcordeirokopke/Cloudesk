module Panel
  # POST /panel/conversations/:conversation_id/resolution: o analista resolve a conversa
  # (Conversations::AnalystActions.resolve!).
  class ResolutionsController < BaseController
    def create
      Conversations::AnalystActions.resolve!(analyst: current_analyst, conversation_id: params[:conversation_id])
      redirect_to panel_conversation_path(params[:conversation_id]), notice: "Conversa resolvida", status: :see_other
    rescue Conversations::AnalystActions::NotAllowed => error
      redirect_to panel_conversation_path(params[:conversation_id]), alert: error.message, status: :see_other
    end
  end
end

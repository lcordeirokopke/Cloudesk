module Panel
  # POST /panel/handoffs/:handoff_id/rating (rating=useful|not_useful): avaliação do briefing pelo
  # analista da conversa (Conversations::AnalystActions.rate_handoff!). Volta à conversa do handoff.
  class HandoffRatingsController < BaseController
    def create
      conversation_id = in_brand { Handoff.where(id: params[:handoff_id]).pick(:conversation_id) }
      raise ActionController::RoutingError, "handoff não encontrado" if conversation_id.nil?

      begin
        Conversations::AnalystActions.rate_handoff!(analyst: current_analyst, handoff_id: params[:handoff_id],
                                                    rating: params[:rating])
        redirect_to panel_conversation_path(conversation_id), notice: "Briefing avaliado", status: :see_other
      rescue Conversations::AnalystActions::NotAllowed => error
        redirect_to panel_conversation_path(conversation_id), alert: error.message, status: :see_other
      end
    end
  end
end

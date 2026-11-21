module Panel
  # GET /panel/conversations/:id: qualquer conversa da marca do analista, com o histórico, o cartão
  # do último handoff, "Por que caiu aqui?", as conversas anteriores do lojista em todos os canais e
  # a memória do lojista, quando existe. Responder e resolver aparecem só com a conversa em
  # with_human atribuída ao analista; a avaliação do briefing, com a conversa dele em with_human ou
  # resolved, uma vez.
  class ConversationsController < BaseController
    PREVIOUS_LIMIT = 10

    def show
      in_brand do
        @conversation = Conversation.includes(:contact, :queue, :attendant).find_by(id: params[:id])
        raise ActionController::RoutingError, "conversa não encontrada" if @conversation.nil?

        @messages = @conversation.messages.includes(:attendant).order(:sequence).to_a
        @handoff = @conversation.handoffs.includes(:rated_by).order(created_at: :desc, id: :desc).first
        @first_response_at = @handoff&.first_human_response_at
        @explanation = Conversations::RoutingExplanation.for(@conversation)
        @previous = Conversation.includes(:queue).where(contact_id: @conversation.contact_id).where.not(id: @conversation.id)
                                .order(created_at: :desc).limit(PREVIOUS_LIMIT).to_a
        @previous_messages = Message.where(conversation_id: @previous.map(&:id)).order(:sequence).group_by(&:conversation_id)
        @memory = CustomerMemory.where(contact_id: @conversation.contact_id).order(updated_at: :desc).first
      end

      mine = @conversation.attendant_id == current_analyst.id
      @attending = mine && @conversation.state == "with_human"
      @can_rate = mine && @handoff.present? && @handoff.rating.nil? &&
                  Conversations::AnalystActions::RATEABLE_STATES.include?(@conversation.state)
    end
  end
end

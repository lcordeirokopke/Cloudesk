module Panel
  # GET /panel/conversations/:conversation_id/messages/:message_id/timeline: linha do tempo de uma
  # mensagem do lojista (Conversations::MessageTimeline), com os saltos e os eventos do trace. Só
  # leitura, na marca do analista; 404 quando a conversa não é da marca ou a mensagem não é do
  # lojista nessa conversa.
  class TimelinesController < BaseController
    def show
      in_brand do
        @conversation = Conversation.includes(:contact).find_by(id: params[:conversation_id])
        raise ActionController::RoutingError, "conversa não encontrada" if @conversation.nil?

        message = Message.find_by(id: params[:message_id], conversation_id: @conversation.id, author: "customer")
        raise ActionController::RoutingError, "mensagem do lojista não encontrada" if message.nil?

        @timeline = Conversations::MessageTimeline.for(message)
      end
    end
  end
end

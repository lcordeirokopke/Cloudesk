module Panel
  # POST /panel/assignments: "Pegar próximo". Atribui ao analista o próximo caso das filas da
  # equipe pela distribuição por capacidade (Routing::Distributor.next_for) e abre a conversa; sem
  # caso disponível ou na capacidade, volta à fila com aviso.
  class AssignmentsController < BaseController
    def create
      conversation = Routing::Distributor.next_for(current_analyst)
      if conversation
        redirect_to panel_conversation_path(conversation.id), status: :see_other
      else
        redirect_to panel_queue_path, alert: "Nenhum caso disponível", status: :see_other
      end
    end
  end
end

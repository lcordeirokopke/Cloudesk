module Panel
  # GET /panel/queue: fila de escalas da equipe do analista e as conversas dele.
  #   - fila: conversas awaiting_human nas filas da equipe, por prioridade (maior primeiro) e tempo
  #     na fila, com o motivo e o resumo do último handoff, o tempo na fila e o SLA restante;
  #   - minhas conversas: with_human atribuídas ao analista, com a capacidade usada.
  # A fila é só leitura: o caso é atribuído por "Pegar próximo" (Panel::AssignmentsController).
  class QueuesController < BaseController
    def show
      in_brand do
        @team = current_analyst.team
        team_queues = Routing::Queue.where(team_id: @team.id).select(:id)
        @waiting = Conversation.includes(:contact, :queue).where(state: "awaiting_human", queue_id: team_queues)
                               .order(priority: :desc, queued_at: :asc, id: :asc).to_a
        @mine = Conversation.includes(:contact, :queue).where(state: "with_human", attendant_id: current_analyst.id)
                            .order(:queued_at, :id).to_a
        @handoffs = Handoff.where(conversation_id: @waiting.map(&:id)).order(:created_at, :id)
                           .index_by(&:conversation_id)
      end
      @now = Time.current
    end
  end
end

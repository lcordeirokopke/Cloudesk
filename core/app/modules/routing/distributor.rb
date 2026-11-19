module Routing
  # Distribuição da fila humana por capacidade. O analista puxa o próximo caso das filas da sua
  # equipe, em uma transação na marca dele:
  #   1. trava a linha do analista (FOR UPDATE): pedidos simultâneos do mesmo analista esperam;
  #   2. conta as conversas with_human do analista; na capacidade, não recebe caso;
  #   3. escolhe a conversa awaiting_human das filas da equipe por prioridade e tempo na fila, com
  #      FOR UPDATE SKIP LOCKED: a conversa travada por outro analista é pulada;
  #   4. passa a conversa para with_human com o analista (conversation.assigned).
  # Devolve a conversa atribuída, ou nil.
  module Distributor
    class << self
      def next_for(attendant)
        brand = Brand.find(attendant.brand_id)

        Tenancy.with_brand(brand) do
          analyst = Attendant.lock.find(attendant.id)
          raise ArgumentError, "só analista humano com equipe recebe caso da fila" unless analyst.kind == "human" && analyst.team_id

          next nil if Conversation.where(attendant_id: analyst.id, state: "with_human").count >= analyst.capacity

          conversation = next_conversation(analyst)
          next nil if conversation.nil?

          assign(brand, analyst, conversation)
        end
      end

      private

      def next_conversation(analyst)
        Conversation.where(state: "awaiting_human", queue_id: Routing::Queue.where(team_id: analyst.team_id).select(:id))
                    .order(priority: :desc, queued_at: :asc, id: :asc)
                    .lock("FOR UPDATE SKIP LOCKED")
                    .first
      end

      def assign(brand, analyst, conversation)
        Audit::Command.call(brand: brand, type: "conversation.assigned", actor_type: "analyst", actor_id: analyst.id) do |change|
          change.before = { state: conversation.state, attendant_id: conversation.attendant_id }
          conversation.update!(state: "with_human", attendant_id: analyst.id)
          change.after = { state: conversation.state, attendant_id: conversation.attendant_id }
          change.target = conversation
          change.conversation = conversation
          change.payload = {
            queue_id: conversation.queue_id, priority: conversation.priority,
            queued_at: conversation.queued_at&.utc&.iso8601(3)
          }
          conversation
        end.value
      end
    end
  end
end

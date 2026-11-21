# Fila de escalação das filas e avaliação do briefing do handoff. Roda com o papel dono; as
# tabelas já têm RLS e as permissões do papel da aplicação.
#
# queues.escalation_queue_id: fila humana da mesma marca que recebe as conversas escaladas.
# handoffs.rating:            avaliação do briefing pelo analista (useful ou not_useful).
# handoffs.rated_by_id:       analista que avaliou.
# handoffs.rated_at:          horário da avaliação.
class AddEscalationQueueAndHandoffRating < ActiveRecord::Migration[8.1]
  def change
    add_column :queues, :escalation_queue_id, :uuid
    add_index :queues, %i[brand_id escalation_queue_id]
    add_foreign_key :queues, :queues, column: %i[brand_id escalation_queue_id], primary_key: %i[brand_id id]

    add_column :handoffs, :rating, :string
    add_column :handoffs, :rated_by_id, :uuid
    add_column :handoffs, :rated_at, :datetime
    add_check_constraint :handoffs, "rating IN ('useful', 'not_useful')", name: "handoffs_rating_check"
    add_index :handoffs, %i[brand_id rated_by_id]
    add_foreign_key :handoffs, :attendants, column: %i[brand_id rated_by_id], primary_key: %i[brand_id id]
  end
end

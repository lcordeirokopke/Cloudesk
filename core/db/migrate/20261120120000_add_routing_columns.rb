# Colunas e índices do roteamento. Roda com o papel dono; as tabelas já têm as permissões do papel
# da aplicação.
#
# routing_rules.active: a versão vigente de uma regra participa da avaliação só quando ativa.
# conversations.urgency: urgência dada pelo classificador (high ou normal).
# conversations.sla_minutes: SLA definido pelo roteamento.
# conversations.queued_at: horário em que a conversa entrou na fila humana.
class AddRoutingColumns < ActiveRecord::Migration[8.1]
  def change
    add_column :routing_rules, :active, :boolean, null: false, default: true

    add_column :conversations, :urgency, :string
    add_column :conversations, :sla_minutes, :integer
    add_column :conversations, :queued_at, :datetime
    add_check_constraint :conversations, "urgency IN ('high', 'normal')", name: "conversations_urgency_check"

    # Contagem das conversas abertas de uma fila, para a capacidade da fila.
    add_index :conversations, %i[brand_id queue_id],
              where: "state IN ('with_ai', 'awaiting_human', 'with_human')",
              name: "index_conversations_open_by_queue"

    # Próximo caso da fila humana, por prioridade e tempo na fila.
    add_index :conversations, %i[brand_id queue_id priority queued_at],
              order: { priority: :desc }, where: "state = 'awaiting_human'",
              name: "index_conversations_awaiting_human"
  end
end

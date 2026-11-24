# Índices parciais das consultas recorrentes sobre conversas abertas. Roda com o papel dono, fora de
# transação: CREATE INDEX CONCURRENTLY não trava a escrita nas tabelas.
#
# index_conversations_with_ai:                 conversas em with_ai por marca (varredura do timeout
#                                              do agente e cockpit);
# index_messages_customer_by_sequence:         última mensagem do lojista de cada conversa (LATERAL da
#                                              varredura e do cockpit);
# index_conversations_with_human_by_attendant: conversas with_human de cada analista (capacidade no
#                                              Routing::Distributor).
class AddPartialIndexesForScale < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :conversations, :brand_id, where: "state = 'with_ai'", name: "index_conversations_with_ai",
                                         algorithm: :concurrently

    add_index :messages, %i[brand_id conversation_id sequence], order: { sequence: :desc },
                                                                where: "author = 'customer'",
                                                                name: "index_messages_customer_by_sequence",
                                                                algorithm: :concurrently

    add_index :conversations, %i[brand_id attendant_id], where: "state = 'with_human'",
                                                         name: "index_conversations_with_human_by_attendant",
                                                         algorithm: :concurrently
  end
end

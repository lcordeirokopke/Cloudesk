# Itens estruturados da memória do lojista. Roda com o papel dono; a tabela já tem RLS e as
# permissões do papel da aplicação.
#
# customer_memories.entries: uma entrada por conversa encerrada do resumo, no formato descrito em
# CustomerMemory.
class AddEntriesToCustomerMemories < ActiveRecord::Migration[8.1]
  def change
    add_column :customer_memories, :entries, :jsonb, null: false, default: []
  end
end

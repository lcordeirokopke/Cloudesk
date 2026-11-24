require "rails_helper"

# Índices parciais das consultas recorrentes sobre conversas abertas, conferidos em pg_indexes.
RSpec.describe "Índices parciais" do
  let(:connection) { ApplicationRecord.lease_connection }

  def definition(name)
    connection.select_value(<<~SQL)
      SELECT indexdef FROM pg_indexes WHERE schemaname = 'public' AND indexname = #{connection.quote(name)}
    SQL
  end

  {
    "index_conversations_with_ai" =>
      "ON public.conversations USING btree (brand_id) WHERE (state = 'with_ai'::conversation_state)",
    "index_messages_customer_by_sequence" =>
      "ON public.messages USING btree (brand_id, conversation_id, sequence DESC) WHERE ((author)::text = 'customer'::text)",
    "index_conversations_with_human_by_attendant" =>
      "ON public.conversations USING btree (brand_id, attendant_id) WHERE (state = 'with_human'::conversation_state)"
  }.each do |name, expected|
    it "#{name} existe com as colunas e o predicado esperados" do
      expect(definition(name)).to eq("CREATE INDEX #{name} #{expected}")
    end
  end
end

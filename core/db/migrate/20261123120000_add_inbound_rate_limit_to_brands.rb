# Limite de taxa de entrada por marca. Roda com o papel dono; brands fica fora do RLS e o papel da
# aplicação só lê.
#
# brands.inbound_rate_limit_per_second: mensagens de entrada aceitas por segundo, por marca, nos
# canais WhatsApp e chat (Channels::RateLimit). Acima dele, a entrada responde 429.
class AddInboundRateLimitToBrands < ActiveRecord::Migration[8.1]
  def change
    add_column :brands, :inbound_rate_limit_per_second, :integer, null: false, default: 500
    add_check_constraint :brands, "inbound_rate_limit_per_second > 0", name: "brands_inbound_rate_limit_per_second_check"
  end
end

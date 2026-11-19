# Marca (InfinitePay, JIM). A tabela brands fica fora do RLS: ela é lida para resolver a marca
# antes de a marca ser definida na transação. O papel da aplicação só lê.
# reopen_window_minutes é o prazo em que uma conversa resolvida volta à triagem quando o lojista
# escreve; vencido o prazo, a conversa passa a closed.
class Brand < ApplicationRecord
  has_many :brand_channels

  validates :slug, :name, :locale, presence: true
  validates :slug, uniqueness: true
  validates :reopen_window_minutes, numericality: { only_integer: true, greater_than: 0 }

  def reopen_window
    reopen_window_minutes.minutes
  end
end

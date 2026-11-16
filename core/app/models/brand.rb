# Marca (InfinitePay, JIM). A tabela brands fica fora do RLS: ela é lida para resolver a marca
# antes de a marca ser definida na transação. O papel da aplicação só lê.
class Brand < ApplicationRecord
  validates :slug, :name, :locale, presence: true
  validates :slug, uniqueness: true
end

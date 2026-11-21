module Admin
  # Erro de uma edição do admin. Nenhum erro deixa gravação: a edição roda em uma transação.
  class Error < StandardError; end
end

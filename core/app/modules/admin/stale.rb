module Admin
  # O registro mudou depois de lido por quem edita (updated_at diferente do lido).
  class Stale < Error; end
end

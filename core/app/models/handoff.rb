# Escalação para humano, com motivo, resumo e contexto estruturado.
class Handoff < ApplicationRecord
  include BrandScoped

  belongs_to :conversation

  validates :reason, :summary, presence: true
end

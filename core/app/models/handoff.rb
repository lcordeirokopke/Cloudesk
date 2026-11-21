# Escalação para humano, com motivo, resumo e contexto estruturado. O analista que atende a
# conversa avalia o briefing uma vez (rating, rated_by, rated_at).
class Handoff < ApplicationRecord
  include BrandScoped

  RATINGS = %w[useful not_useful].freeze

  belongs_to :conversation
  belongs_to :rated_by, class_name: "Attendant", optional: true

  validates :reason, :summary, presence: true
  validates :rating, inclusion: { in: RATINGS }, allow_nil: true
  validates :rated_by, :rated_at, presence: true, if: :rating

  # Horário da primeira mensagem de analista da conversa a partir da criação do handoff; nil quando
  # o analista ainda não respondeu.
  def first_human_response_at
    Message.where(conversation_id: conversation_id, author: "analyst").where(created_at: created_at..).minimum(:created_at)
  end
end

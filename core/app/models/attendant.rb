# Atendente da plataforma: o agente de IA (ai) ou um analista (human).
class Attendant < ApplicationRecord
  include BrandScoped

  KINDS = %w[ai human].freeze

  belongs_to :team, optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true
  validates :capacity, numericality: { only_integer: true, greater_than: 0 }

  # O atendente IA da marca corrente; com mais de um, o primeiro por nome. nil quando não existe.
  def self.first_ai
    where(kind: "ai").order(:name, :id).first
  end
end

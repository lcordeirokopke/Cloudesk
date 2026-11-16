# Resumo das interações anteriores de um lojista.
class CustomerMemory < ApplicationRecord
  include BrandScoped

  belongs_to :contact

  validates :summary, presence: true
end

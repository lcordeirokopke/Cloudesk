# Identidade de um lojista em um canal: telefone (whatsapp), e-mail (email) ou id do app (chat).
# É única por marca.
class ContactIdentity < ApplicationRecord
  include BrandScoped

  CHANNELS = %w[chat whatsapp email].freeze

  belongs_to :contact

  validates :channel, inclusion: { in: CHANNELS }
  validates :value, presence: true
end

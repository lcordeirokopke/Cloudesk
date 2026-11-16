# Mensagem de uma conversa, com canal, autor e sequência por conversa.
# É criada por Conversation#append_message!, que define a sequência.
class Message < ApplicationRecord
  include BrandScoped

  AUTHORS = %w[customer ai analyst system].freeze

  belongs_to :conversation
  belongs_to :attendant, optional: true

  validates :channel, inclusion: { in: ContactIdentity::CHANNELS }
  validates :author, inclusion: { in: AUTHORS }
  validates :body, presence: true
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
end

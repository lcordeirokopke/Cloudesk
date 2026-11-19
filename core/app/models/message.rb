# Mensagem de uma conversa, com canal, autor e sequência por conversa.
# É criada por Conversation#append_message!, que define a sequência.
#   external_id:   id gerado por quem envia (wamid, Message-ID, id do cliente no chat); o mesmo id
#                  no mesmo canal é reenvio técnico.
#   attachments:   metadados dos anexos, sem o arquivo: lista de objetos com kind e, quando
#                  existem, filename, content_type e size.
#   brand_channel: número ou e-mail da marca que recebeu a mensagem; vazio no chat.
class Message < ApplicationRecord
  include BrandScoped

  AUTHORS = %w[customer ai analyst system].freeze
  ATTACHMENT_KINDS = %w[image document audio video other].freeze
  ATTACHMENT_KEYS = %w[kind filename content_type size].freeze

  belongs_to :conversation
  belongs_to :attendant, optional: true
  belongs_to :brand_channel, optional: true

  validates :channel, inclusion: { in: ContactIdentity::CHANNELS }
  validates :author, inclusion: { in: AUTHORS }
  validates :body, presence: true
  validates :sequence, numericality: { only_integer: true, greater_than: 0 }
  validate :attachments_format

  def attachments=(value)
    super(Array(value).map { |attachment| attachment.respond_to?(:to_h) ? attachment.to_h.stringify_keys.compact : attachment })
  end

  private

  def attachments_format
    valid = attachments.is_a?(Array) && attachments.all? do |attachment|
      attachment.is_a?(Hash) &&
        ATTACHMENT_KINDS.include?(attachment["kind"]) &&
        (attachment.keys - ATTACHMENT_KEYS).empty?
    end
    errors.add(:attachments, "deve ser uma lista de objetos com kind e, opcionalmente, #{ATTACHMENT_KEYS.drop(1).join(', ')}") unless valid
  end
end

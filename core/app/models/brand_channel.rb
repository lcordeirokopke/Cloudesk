# Número de WhatsApp ou e-mail de suporte de uma marca. O par (channel, value) define a marca da
# mensagem recebida. A tabela fica fora do RLS, como brands: é lida antes de a marca ser definida na
# transação. O papel da aplicação só lê; os registros vêm das seeds.
#   whatsapp: value é o phone_number_id da Cloud API; display_value é o número exibido.
#   email:    value é o e-mail normalizado; display_value é igual a value.
class BrandChannel < ApplicationRecord
  CHANNELS = %w[whatsapp email].freeze

  belongs_to :brand

  before_validation :normalize_email

  validates :channel, inclusion: { in: CHANNELS }
  validates :value, presence: true

  # Canal da marca com o valor informado, ou nil.
  def self.lookup(channel, value)
    value = Channels::Identity.normalize("email", value) if channel.to_s == "email"
    return nil if value.blank?

    find_by(channel: channel.to_s, value: value)
  end

  private

  def normalize_email
    return unless channel == "email"

    self.value = Channels::Identity.normalize("email", value)
    self.display_value ||= value
  end
end

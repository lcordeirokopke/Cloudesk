module Channels
  # Envelope canônico de entrada, comum aos três canais. Cada adaptador confere a autenticidade e
  # converte o formato do canal neste envelope; daí em diante o caminho é Conversations::Intake.
  #   brand:         Brand da mensagem.
  #   brand_channel: BrandChannel que recebeu a mensagem; nil no chat.
  #   channel:       chat, whatsapp ou email.
  #   identity:      identidade do lojista no canal, já normalizada (Channels::Identity).
  #   contact_name:  nome do lojista informado pelo canal, usado quando o lojista é novo.
  #   external_id:   id da mensagem gerado por quem envia; o mesmo id no mesmo canal é reenvio.
  #   text:          texto da mensagem; vazio quando a mensagem só tem anexos.
  #   attachments:   metadados dos anexos (kind, filename, content_type, size).
  #   received_at:   horário em que o Core recebeu a mensagem.
  #   subject:       assunto do e-mail; nil nos outros canais.
  InboundMessage = Data.define(
    :brand, :brand_channel, :channel, :identity, :contact_name, :external_id, :text, :attachments,
    :received_at, :subject
  ) do
    def initialize(brand:, channel:, identity:, received_at:, brand_channel: nil, contact_name: nil,
                   external_id: nil, text: nil, attachments: [], subject: nil)
      raise ArgumentError, "brand deve ser um Brand" unless brand.is_a?(Brand)
      raise ArgumentError, "canal desconhecido: #{channel.inspect}" unless ContactIdentity::CHANNELS.include?(channel.to_s)
      raise ArgumentError, "identidade não informada" if identity.blank?
      raise ArgumentError, "received_at não informado" if received_at.nil?

      super(
        brand: brand, brand_channel: brand_channel, channel: channel.to_s, identity: identity,
        contact_name: contact_name, external_id: external_id.presence, text: text.to_s.strip,
        attachments: Array(attachments).map { |attachment| attachment.to_h.stringify_keys.compact },
        received_at: received_at, subject: subject
      )
    end
  end
end

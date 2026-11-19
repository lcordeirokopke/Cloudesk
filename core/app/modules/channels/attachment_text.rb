module Channels
  # Texto padrão de uma mensagem sem texto, no locale da marca, pelo tipo do anexo:
  # image, document, audio, video ou other. Ex.: "[imagem enviada]" em pt-BR.
  module AttachmentText
    module_function

    def for(brand, kind)
      kind = Message::ATTACHMENT_KINDS.include?(kind.to_s) ? kind.to_s : "other"
      I18n.t("channels.attachment_text.#{kind}", locale: brand.locale)
    end
  end
end

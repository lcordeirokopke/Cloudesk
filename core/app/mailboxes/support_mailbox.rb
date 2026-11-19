# Converte o e-mail do lojista em Channels::InboundMessage e grava pelo Conversations::Intake.
#   - marca e BrandChannel: o primeiro destinatário (To, depois Cc) presente em brand_channels; sem
#     nenhum, o e-mail é marcado como bounced, sem envio de e-mail;
#   - received_at: criação do InboundEmail; o trace começa aqui;
#   - identidade: endereço do From normalizado; nome: nome de exibição do From, ou a parte local do
#     endereço;
#   - external_id: Message-ID; subject: assunto, usado na resposta;
#   - texto: parte text/plain ou, sem ela, o HTML sem tags; sem as linhas que começam com ">" e sem
#     tudo a partir de uma linha "On … wrote:" ou "Em … escreveu:"; texto vazio com anexos recebe o
#     texto padrão do Intake;
#   - anexos: kind, filename, content_type e size de cada anexo, sem o arquivo.
class SupportMailbox < ApplicationMailbox
  QUOTE_HEADER = /\A\s*(On\s.*\swrote:|Em\s.*\sescreveu:)\s*\z/

  def process
    brand_channel = support_channel
    return bounced! if brand_channel.nil?

    identity = Channels::Identity.normalize("email", Array(mail.from).first)
    return bounced! if identity.nil?

    Current.received_at = inbound_email.created_at
    Current.traceparent = TraceContext.generate

    Conversations::Intake.call(
      Channels::InboundMessage.new(
        brand: brand_channel.brand,
        brand_channel: brand_channel,
        channel: "email",
        identity: identity,
        contact_name: sender_name(identity),
        external_id: mail.message_id,
        text: text,
        attachments: attachments,
        received_at: Current.received_at,
        subject: mail.subject
      )
    )
  end

  private

  def support_channel
    (Array(mail.to) + Array(mail.cc)).lazy.filter_map { |address| BrandChannel.lookup("email", address) }.first
  end

  def sender_name(identity)
    display_name = mail[:from].respond_to?(:display_names) ? Array(mail[:from].display_names).first : nil
    display_name.presence || identity.split("@").first
  end

  def text
    strip_quote(utf8(raw_text))
  end

  def raw_text
    if mail.multipart?
      return mail.text_part.decoded if mail.text_part

      html_to_text(mail.html_part&.decoded)
    elsif mail.mime_type == "text/html"
      html_to_text(mail.decoded)
    else
      mail.decoded
    end
  end

  def html_to_text(html)
    Rails::HTML5::FullSanitizer.new.sanitize(html.to_s)
  end

  def utf8(text)
    text = text.to_s
    return text.dup.force_encoding(Encoding::UTF_8).scrub if text.encoding == Encoding::BINARY

    text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
  end

  def strip_quote(text)
    lines = text.gsub("\r\n", "\n").split("\n")
    cut = lines.index { |line| line.match?(QUOTE_HEADER) }
    lines = lines.first(cut) if cut
    lines.reject { |line| line.start_with?(">") }.join("\n").strip
  end

  def attachments
    mail.attachments.map do |attachment|
      {
        kind: attachment_kind(attachment.mime_type),
        filename: attachment.filename,
        content_type: attachment.mime_type,
        size: attachment.decoded.bytesize
      }
    end
  end

  def attachment_kind(mime_type)
    case mime_type.to_s
    when %r{\Aimage/} then "image"
    when %r{\Aaudio/} then "audio"
    when %r{\Avideo/} then "video"
    else "document"
    end
  end
end

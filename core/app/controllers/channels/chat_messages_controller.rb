module Channels
  # Entrada JSON do chat para o simulador de canais e o k6.
  #   POST /channels/chat/messages
  #   { "brand": "infinitepay", "app_user_id": "app-…", "client_message_id": "…", "text": "…",
  #     "attachments": [ { "kind": "image", "filename": "…", "content_type": "…", "size": 123 } ] }
  # A chamada é assinada com Contract::Signature e o segredo CHAT_SIGNING_SECRET, sobre método,
  # caminho e corpo bruto. Responde conversation_id, sequence e stream, o nome assinado do stream
  # Turbo do lojista. O reenvio do mesmo client_message_id devolve a mensagem existente.
  class ChatMessagesController < ActionController::API
    def create
      return head(:unauthorized) unless signed?

      data = parse(request.raw_post)
      return render_error("corpo JSON inválido") if data.nil?

      brand = Brand.find_by(slug: data["brand"].to_s)
      return render_error("marca desconhecida") if brand.nil?

      inbound = build_inbound(brand, data)
      return render_error(inbound) if inbound.is_a?(String)

      result = Conversations::Intake.call(inbound).first
      render json: {
        conversation_id: result.conversation.id,
        sequence: result.message.sequence,
        stream: Chat.signed_stream_name(result.contact)
      }, status: :ok
    end

    private

    def signed?
      Contract::Signature.verify!(
        secret: Settings.chat_signing_secret,
        timestamp: request.headers[Contract::Signature::TIMESTAMP_HEADER],
        signature: request.headers[Contract::Signature::SIGNATURE_HEADER],
        method: request.request_method,
        path: request.fullpath,
        body: request.raw_post
      )
    rescue Contract::Signature::Error
      false
    end

    def parse(body)
      data = JSON.parse(body)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end

    # Devolve a InboundMessage, ou a mensagem de erro.
    def build_inbound(brand, data)
      identity = Identity.normalize("chat", data["app_user_id"])
      return "app_user_id não informado" if identity.nil?
      return "client_message_id não informado" if data["client_message_id"].to_s.strip.empty?

      attachments = data["attachments"] || []
      return "attachments deve ser uma lista de objetos com kind" unless valid_attachments?(attachments)
      return "text ou attachments deve ser informado" if data["text"].to_s.strip.empty? && attachments.empty?

      InboundMessage.new(
        brand: brand, channel: "chat", identity: identity, external_id: data["client_message_id"].to_s.strip,
        text: data["text"], attachments: attachments.map { |attachment| attachment.slice(*Message::ATTACHMENT_KEYS) },
        received_at: Current.received_at
      )
    end

    def valid_attachments?(attachments)
      attachments.is_a?(Array) &&
        attachments.all? { |attachment| attachment.is_a?(Hash) && Message::ATTACHMENT_KINDS.include?(attachment["kind"]) }
    end

    def render_error(message)
      render json: { error: message }, status: :unprocessable_content
    end
  end
end

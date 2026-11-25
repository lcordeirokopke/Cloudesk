module Channels
  # Widget de chat in-app (Hotwire), com login simulado: a pessoa escolhe um lojista da marca com
  # identidade de chat, e o app_user_id fica na sessão, por marca.
  #   GET  /chat/:brand               lojistas com identidade de chat
  #   POST /chat/:brand/session       grava o app_user_id na sessão
  #   GET  /chat/:brand/conversation  histórico da conversa aberta e stream Turbo do lojista
  #   POST /chat/:brand/messages      envia a mensagem; client_message_id gerado no navegador
  # Antes de gravar, a mensagem conta no limite do widget (Channels::RateLimit.check_widget), por
  # lojista e por marca; acima dele, a resposta é a tela da conversa com 429, Retry-After, aviso e o
  # texto no campo, e nada é gravado. A mensagem vazia não conta.
  class ChatWidgetController < ApplicationController
    before_action :set_brand
    before_action :set_contact, only: %i[conversation create_message]

    def index
      @identities = Tenancy.with_brand(@brand) do
        ContactIdentity.where(channel: "chat").includes(:contact).order(:value).to_a
      end
    end

    def create_session
      identity = Identity.normalize("chat", params[:app_user_id])
      exists = identity && Tenancy.with_brand(@brand) { ContactIdentity.exists?(channel: "chat", value: identity) }
      return redirect_to(chat_path(@brand.slug), alert: "Lojista não encontrado") unless exists

      session[session_key] = identity
      redirect_to chat_conversation_path(@brand.slug)
    end

    def conversation
      @messages = load_messages
    end

    def create_message
      text = params[:text].to_s.strip
      client_message_id = params[:client_message_id].to_s.strip
      if text.empty? || client_message_id.empty?
        return redirect_to(chat_conversation_path(@brand.slug), alert: "Mensagem vazia")
      end

      limit = RateLimit.check_widget(@brand, @contact)
      return rate_limited(limit, text) unless limit.allowed

      Conversations::Intake.call(
        InboundMessage.new(
          brand: @brand, channel: "chat", identity: session[session_key], external_id: client_message_id,
          text: text, received_at: Current.received_at
        )
      )
      redirect_to chat_conversation_path(@brand.slug), status: :see_other
    end

    private

    # O texto volta ao campo, e o navegador gera outro client_message_id no envio seguinte.
    def rate_limited(limit, text)
      response.set_header("Retry-After", limit.retry_after.to_s)
      flash.now[:alert] = "Muitas mensagens em pouco tempo. Aguarde #{limit.retry_after} s e envie de novo."
      @text = text
      @messages = load_messages
      render :conversation, status: :too_many_requests
    end

    def load_messages
      Tenancy.with_brand(@brand) do
        open_conversation = Conversation.where(contact_id: @contact.id).where.not(state: "closed").first
        open_conversation ? open_conversation.messages.order(:sequence).to_a : []
      end
    end

    def set_brand
      @brand = Brand.find_by!(slug: params[:brand])
    end

    def set_contact
      identity = session[session_key]
      @contact = identity && Tenancy.with_brand(@brand) do
        ContactIdentity.find_by(channel: "chat", value: identity)&.contact
      end
      redirect_to chat_path(@brand.slug) if @contact.nil?
    end

    def session_key
      "chat_app_user_id_#{@brand.slug}"
    end
  end
end

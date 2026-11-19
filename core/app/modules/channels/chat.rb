module Channels
  # Chat in-app: o stream Turbo é por lojista, e não por conversa; o widget continua inscrito quando
  # uma conversa nova é aberta.
  module Chat
    TARGET = "messages".freeze
    PARTIAL = "channels/chat/message".freeze

    module_function

    def streamables(contact)
      [ contact, :chat ]
    end

    # Nome assinado do stream do lojista, para assinar o stream por WebSocket.
    def signed_stream_name(contact)
      Turbo::StreamsChannel.signed_stream_name(streamables(contact))
    end

    # Acrescenta a mensagem ao histórico do widget do lojista.
    def broadcast(contact, message)
      Turbo::StreamsChannel.broadcast_append_to(
        *streamables(contact), target: TARGET, partial: PARTIAL, locals: { message: message }
      )
    end
  end
end

module Channels
  # Resposta ao lojista por e-mail, enviada pelo e-mail de suporte da marca que recebeu a mensagem.
  # Assunto, In-Reply-To e References vêm do último e-mail do lojista na conversa, para a resposta
  # entrar na mesma thread do cliente de e-mail.
  class ReplyMailer < ApplicationMailer
    # from:        e-mail de suporte da marca.
    # to:          e-mail do lojista.
    # subject:     assunto do último e-mail do lojista, ou nil.
    # in_reply_to: Message-ID do último e-mail do lojista, sem os sinais < e >, ou nil.
    # message_id:  id da Message do Core, no header X-Cloudesk-Message-Id.
    def reply(from:, to:, subject:, in_reply_to:, message_id:, body:)
      @body = body
      headers["X-Cloudesk-Message-Id"] = message_id
      if in_reply_to.present?
        headers["In-Reply-To"] = "<#{in_reply_to}>"
        headers["References"] = "<#{in_reply_to}>"
      end

      mail(from: from, to: to, subject: reply_subject(subject))
    end

    private

    def reply_subject(subject)
      subject = subject.to_s.strip
      subject.match?(/\Are:/i) ? subject : "Re: #{subject}".strip
    end
  end
end

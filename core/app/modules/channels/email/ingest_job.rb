module Channels
  module Email
    # Traz um e-mail do Mailpit para o Action Mailbox. Baixa o original e confere os destinatários
    # (To e Cc) e o remetente contra brand_channels:
    #   - algum destinatário é e-mail de suporte e o remetente não é: cria o InboundEmail e marca a
    #     tag cloudesk-ingested;
    #   - caso contrário (por exemplo, a resposta do próprio Core ao lojista): marca a tag
    #     cloudesk-ignored e não cria nada.
    # O índice único de action_mailbox_inbound_emails em (message_id, message_checksum) impede o mesmo
    # e-mail duas vezes: create_and_extract_message_id! trata a colisão e devolve nil.
    # Depois do commit do InboundEmail, o Action Mailbox enfileira o ActionMailbox::RoutingJob.
    class IngestJob < ApplicationJob
      queue_as :default

      INGESTED_TAG = "cloudesk-ingested".freeze
      IGNORED_TAG = "cloudesk-ignored".freeze

      MAX_ATTEMPTS = 10
      JITTER = 0.15
      BACKOFF = ->(executions) { (2**executions) * (1 + (rand * JITTER)) }

      retry_on Mailpit::Client::Error, wait: BACKOFF, attempts: MAX_ATTEMPTS

      def perform(mailpit_id)
        client = Mailpit::Client.new
        source = client.raw(mailpit_id)

        if support_email?(Mail.new(source))
          ActionMailbox::InboundEmail.create_and_extract_message_id!(source)
          client.tag([ mailpit_id ], [ INGESTED_TAG ])
        else
          client.tag([ mailpit_id ], [ IGNORED_TAG ])
        end
      end

      private

      def support_email?(mail)
        recipients = (Array(mail.to) + Array(mail.cc)).filter_map { |address| Identity.normalize("email", address) }
        sender = Identity.normalize("email", Array(mail.from).first)

        recipients.any? && BrandChannel.where(channel: "email", value: recipients).exists? &&
          (sender.nil? || !BrandChannel.exists?(channel: "email", value: sender))
      end
    end
  end
end

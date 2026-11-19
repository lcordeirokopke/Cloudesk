require "net/http"
require "net/smtp"

module Channels
  # Entrega de uma mensagem de atendente ao lojista, na fila channels. É enfileirado por
  # Conversations::Outbound na mesma transação da mensagem (outbox); por isso
  # enqueue_after_transaction_commit fica desligado.
  #   whatsapp: POST ao simulador no formato da Cloud API (Channels::Whatsapp::Sender);
  #   email:    SMTP ao Mailpit (Channels::ReplyMailer);
  #   chat:     Turbo Stream no stream do lojista (Channels::Chat).
  # Depois de entregar, grava message.delivered com o horário da entrega, que é o fim da medida
  # ponta a ponta. A entrega é at-least-once: uma queda entre o envio e a gravação do evento repete o
  # envio, e o id da mensagem segue em cada entrega para a reconciliação detectar a repetição.
  class DeliveryJob < ApplicationJob
    queue_as :channels

    self.enqueue_after_transaction_commit = false

    MAX_ATTEMPTS = 10

    retry_on DeliveryError::Transient, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
             Errno::ECONNRESET, Net::SMTPServerBusy, wait: EXPONENTIAL_BACKOFF, attempts: MAX_ATTEMPTS

    # Dados da entrega, lidos na marca do job.
    #   recipient:   identidade do lojista que escreveu a mensagem respondida;
    #   subject e in_reply_to: assunto e Message-ID do último e-mail do lojista na conversa.
    Delivery = Data.define(:message, :conversation, :contact, :brand_channel, :recipient, :subject, :in_reply_to)

    def perform(brand_id:, message_id:, traceparent:)
      Current.traceparent = TraceContext.continue(traceparent)
      brand = Brand.find(brand_id)
      delivery = Tenancy.with_brand(brand) { load_delivery(message_id) }

      deliver(delivery)
      record_delivered(brand, delivery, Time.current)
    end

    private

    def load_delivery(message_id)
      message = Message.find(message_id)
      conversation = message.conversation
      replied_sequence = event_payload(message).fetch("in_reply_to_sequence")
      replied = Message.find_by!(conversation_id: conversation.id, sequence: replied_sequence)
      last_email = Message.where(conversation_id: conversation.id, author: "customer", channel: "email")
                          .order(sequence: :desc).first
      email_payload = last_email ? event_payload(last_email) : {}

      Delivery.new(
        message: message,
        conversation: conversation,
        contact: conversation.contact,
        brand_channel: message.brand_channel,
        recipient: event_payload(replied)["identity"],
        subject: email_payload["subject"],
        in_reply_to: email_payload["external_id"]
      )
    end

    # Payload do message.created da mensagem, gravado em audit_events.
    def event_payload(message)
      AuditEvent.find_by!(conversation_id: message.conversation_id, action: "message.created",
                          target_type: "Message", target_id: message.id)
                .payload.fetch("payload")
    end

    def deliver(delivery)
      message = delivery.message
      case message.channel
      when "whatsapp"
        Whatsapp::Sender.deliver(
          phone_number_id: delivery.brand_channel.value, to: recipient!(delivery), text: message.body,
          message_id: message.id, traceparent: Current.traceparent.to_s
        )
      when "email"
        ReplyMailer.reply(
          from: delivery.brand_channel.value, to: recipient!(delivery), subject: delivery.subject,
          in_reply_to: delivery.in_reply_to, message_id: message.id, body: message.body
        ).deliver_now!
      when "chat"
        Chat.broadcast(delivery.contact, message)
      end
    end

    def recipient!(delivery)
      delivery.recipient.presence ||
        raise(DeliveryError::Permanent, "mensagem respondida sem identidade do lojista")
    end

    def record_delivered(brand, delivery, delivered_at)
      Audit::Command.call(brand: brand, type: "message.delivered", actor_type: "system") do |change|
        change.target = delivery.message
        change.conversation = delivery.conversation
        change.sequence = delivery.message.sequence
        change.payload = { channel: delivery.message.channel, delivered_at: delivered_at.utc.iso8601(3) }
        delivery.message
      end
    end
  end
end

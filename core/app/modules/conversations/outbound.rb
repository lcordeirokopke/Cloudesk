module Conversations
  # Grava a mensagem de um atendente (IA, analista ou sistema) e enfileira a entrega ao lojista na
  # mesma transação (outbox): a resposta só sai se a mensagem foi gravada.
  # A resposta sai no canal da mensagem respondida (in_reply_to_sequence), pela mesma BrandChannel
  # que a recebeu: o mesmo número ou o mesmo e-mail.
  module Outbound
    AUTHORS = %w[ai analyst system].freeze

    module_function

    # Devolve a Message gravada.
    def append!(conversation:, author:, text:, in_reply_to_sequence:, attendant: nil)
      author = author.to_s
      raise ArgumentError, "autor inválido para mensagem de saída: #{author.inspect}" unless AUTHORS.include?(author)

      brand = Brand.find(conversation.brand_id)
      Current.traceparent ||= TraceContext.generate

      Audit::Command.call(brand: brand, type: "message.created", actor_type: author, actor_id: attendant&.id) do |change|
        replied = Message.find_by!(conversation_id: conversation.id, sequence: in_reply_to_sequence)
        message = conversation.append_message!(
          channel: replied.channel, author: author, attendant_id: attendant&.id, body: text,
          brand_channel_id: replied.brand_channel_id
        )
        change.target = message
        change.conversation = conversation
        change.sequence = message.sequence
        change.payload = {
          message: { author: author, channel: message.channel, text: text },
          in_reply_to_sequence: in_reply_to_sequence
        }

        Channels::DeliveryJob.perform_later(
          brand_id: brand.id, message_id: message.id, traceparent: Current.traceparent.to_s
        )
        message
      end.value
    end
  end
end

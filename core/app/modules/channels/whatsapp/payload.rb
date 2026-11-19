module Channels
  module Whatsapp
    # Converte o webhook da Cloud API da Meta em Channels::InboundMessage.
    # Percorre entry[].changes[] com field == "messages":
    #   - a marca e a BrandChannel vêm de value.metadata.phone_number_id; número desconhecido é
    #     ignorado com log;
    #   - o nome do lojista vem de value.contacts[], casando wa_id com messages[].from;
    #   - text: texto de text.body; image, document, audio e video: metadados do anexo e o texto da
    #     caption, ou o texto padrão; outros tipos: texto padrão "other";
    #   - external_id é messages[].id (wamid); a identidade é messages[].from normalizado;
    #     mensagem sem from é ignorada com log;
    #   - value.statuses é ignorado.
    class Payload
      MEDIA_TYPES = %w[image document audio video].freeze

      def initialize(data, received_at:, logger: Rails.logger)
        @data = data.is_a?(Hash) ? data : {}
        @received_at = received_at
        @logger = logger
      end

      def inbound_messages
        changes.flat_map { |value| messages_of(value) }
      end

      private

      def changes
        Array(@data["entry"]).flat_map { |entry| Array(entry.is_a?(Hash) ? entry["changes"] : nil) }
                             .select { |change| change.is_a?(Hash) && change["field"] == "messages" }
                             .map { |change| change["value"] }
                             .select { |value| value.is_a?(Hash) }
      end

      def messages_of(value)
        messages = Array(value["messages"])
        return [] if messages.empty?

        phone_number_id = value.dig("metadata", "phone_number_id").to_s
        brand_channel = BrandChannel.lookup("whatsapp", phone_number_id)
        if brand_channel.nil?
          @logger.warn("WhatsApp: phone_number_id desconhecido #{phone_number_id.inspect}; #{messages.size} mensagem(ns) ignorada(s)")
          return []
        end

        names = Array(value["contacts"]).to_h { |contact| [ contact["wa_id"].to_s, contact.dig("profile", "name") ] }
        messages.filter_map { |message| inbound_message(message, brand_channel, names) }
      end

      def inbound_message(message, brand_channel, names)
        identity = Identity.normalize("whatsapp", message["from"])
        if identity.nil?
          @logger.warn("WhatsApp: mensagem #{message['id'].inspect} sem from; ignorada")
          return nil
        end

        text, attachments = content(message)
        InboundMessage.new(
          brand: brand_channel.brand,
          brand_channel: brand_channel,
          channel: "whatsapp",
          identity: identity,
          contact_name: names[message["from"].to_s],
          external_id: message["id"],
          text: text,
          attachments: attachments,
          received_at: @received_at
        )
      end

      # Texto e anexos da mensagem, pelo tipo.
      def content(message)
        type = message["type"].to_s
        if type == "text"
          [ message.dig("text", "body"), [] ]
        elsif MEDIA_TYPES.include?(type)
          media = message[type].is_a?(Hash) ? message[type] : {}
          attachment = { kind: type, filename: media["filename"], content_type: media["mime_type"] }
          [ media["caption"], [ attachment ] ]
        else
          [ nil, [ { kind: "other" } ] ]
        end
      end
    end
  end
end

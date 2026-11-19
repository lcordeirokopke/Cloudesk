module Channels
  # Webhook do WhatsApp no formato da Cloud API da Meta; o simulador de canais faz o papel da Meta.
  #   GET:  verificação; responde o hub.challenge quando hub.mode é subscribe e o hub.verify_token
  #         confere.
  #   POST: confere X-Hub-Signature-256 sobre o corpo bruto e grava as mensagens do payload, uma
  #         transação por marca. O 200 sai depois do commit. phone_number_id desconhecido e reenvio
  #         também recebem 200: a Meta reenviaria uma resposta de erro sem fim.
  class WhatsappWebhooksController < ActionController::API
    def verify
      token = params["hub.verify_token"].to_s
      if params["hub.mode"] == "subscribe" && ActiveSupport::SecurityUtils.secure_compare(token, Settings.whatsapp_verify_token)
        render plain: params["hub.challenge"].to_s, status: :ok
      else
        head :forbidden
      end
    end

    def receive
      body = request.raw_post
      return head(:unauthorized) unless Whatsapp::Signature.valid?(body, request.headers[Whatsapp::Signature::HEADER])

      data = parse(body)
      return head(:bad_request) if data.nil?

      inbound_messages = Whatsapp::Payload.new(data, received_at: Current.received_at).inbound_messages
      inbound_messages.group_by { |inbound| inbound.brand.id }.each_value do |messages|
        Conversations::Intake.call(messages)
      end

      head :ok
    end

    private

    def parse(body)
      data = JSON.parse(body)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end
  end
end

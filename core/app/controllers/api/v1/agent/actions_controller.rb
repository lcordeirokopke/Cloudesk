module Api
  module V1
    module Agent
      # API de ações do agente, chamada pelo Broker (broker-consumer).
      #   POST /api/v1/agent/actions
      # O corpo é o valor Kafka de agent.outbound, sem alteração; a marca e a conversa vêm do corpo
      # assinado. A chamada é assinada com AGENT_ACTIONS_SECRET e leva o header Idempotency-Key.
      # Códigos: 200 accepted, inclusive na repetição da chave; 409 stale ou rejected, resultado final
      # para o Broker; 400 missing_idempotency_key; 401 invalid_signature ou expired_timestamp;
      # 404 not_found; 422 invalid_payload. O processamento fica em Agents::ActionProcessor.
      class ActionsController < BaseController
        before_action :verify_signature

        def create
          idempotency_key = request.headers[Contract::IdempotencyKey::HEADER].to_s
          if idempotency_key.empty?
            return render_error(:bad_request, "missing_idempotency_key", "header #{Contract::IdempotencyKey::HEADER} ausente")
          end

          action = parse(request.raw_post)
          return render_error(:unprocessable_content, "invalid_payload", "corpo JSON inválido") if action.nil?

          result = Agents::ActionProcessor.call(action: action, idempotency_key: idempotency_key)
          render json: result.body, status: result.status
        end

        private

        def signing_secret = Agents::Settings.agent_actions_secret

        def parse(body)
          data = JSON.parse(body.to_s)
          data.is_a?(Hash) ? data : nil
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end

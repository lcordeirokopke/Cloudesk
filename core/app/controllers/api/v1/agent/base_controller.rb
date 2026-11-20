module Api
  module V1
    module Agent
      # Base da API do agente no Core. Toda chamada é assinada com Contract::Signature sobre método,
      # caminho com a query string (request.fullpath) e corpo bruto, com o segredo de cada rota. A
      # assinatura é conferida antes de qualquer leitura do banco.
      # Os erros seguem o status error do schema action-response:
      #   401 invalid_signature ou expired_timestamp; 404 not_found.
      class BaseController < ActionController::API
        UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

        rescue_from ActiveRecord::RecordNotFound do
          render_error(:not_found, "not_found", "registro não encontrado")
        end

        private

        # Segredo da assinatura da rota.
        def signing_secret
          raise NotImplementedError
        end

        def verify_signature
          Contract::Signature.verify!(
            secret: signing_secret,
            timestamp: request.headers[Contract::Signature::TIMESTAMP_HEADER],
            signature: request.headers[Contract::Signature::SIGNATURE_HEADER],
            method: request.request_method,
            path: request.fullpath,
            body: request.raw_post.to_s
          )
        rescue Contract::Signature::Expired
          render_error(:unauthorized, "expired_timestamp", "timestamp fora da janela de #{Contract::Signature::TOLERANCE_SECONDS} s")
        rescue Contract::Signature::Invalid
          render_error(:unauthorized, "invalid_signature", "assinatura inválida")
        end

        def render_error(status, code, message)
          render json: { status: "error", error: code, message: message }, status: status
        end
      end
    end
  end
end

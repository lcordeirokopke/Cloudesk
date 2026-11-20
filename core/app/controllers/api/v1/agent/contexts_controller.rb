module Api
  module V1
    module Agent
      # Contexto da conversa para o agente: a context_url do webhook message.created.
      #   GET /api/v1/agent/brands/:brand/conversations/:conversation_id/context
      # Assinado pelo agente com AGENT_CONTEXT_SECRET. A marca vem do slug do caminho, que entra na
      # assinatura; a conversa é lida dentro de Tenancy.with_brand dessa marca, e a conversa de outra
      # marca responde 404. O corpo segue o schema context (Agents::ConversationContext).
      class ContextsController < BaseController
        before_action :verify_signature

        def show
          brand = Brand.find_by(slug: params[:brand])
          return render_error(:not_found, "not_found", "marca #{params[:brand]} não encontrada") if brand.nil?
          return render_error(:not_found, "not_found", "conversa não encontrada") unless params[:conversation_id].match?(UUID)

          render json: Tenancy.with_brand(brand) { Agents::ConversationContext.call(params[:conversation_id]) }
        end

        private

        def signing_secret = Agents::Settings.agent_context_secret
      end
    end
  end
end

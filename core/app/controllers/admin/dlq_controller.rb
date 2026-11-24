module Admin
  # Tela da DLQ Kafka (agent.dlq) da marca da sessão. A listagem vem do broker-web
  # (Admin::DlqClient), cruzada com os dlq.reprocessed da marca pela origem (partição e offset) para
  # mostrar os reprocessamentos anteriores. O reprocessamento é de uma mensagem por vez
  # (Admin::DlqReprocessor) e pode ser repetido. Erro do Broker na listagem aparece na página.
  class DlqController < BaseController
    LIMIT = 50

    def index
      @messages = DlqClient.list(brand: current_brand, limit: LIMIT)
      @blocked = DlqReprocessor.blocked_reasons(brand: current_brand, messages: @messages)
      @history = in_brand { reprocessed_by_source }
    rescue DlqClient::Error => error
      @messages = []
      @blocked = {}
      @history = {}
      @error = error.message
    end

    def reprocess
      command = DlqReprocessor.call(brand: current_brand, partition: params[:partition], offset: params[:offset],
                                    operator_name: operator_name)
      destination = command.value.fetch("destination")
      notice = "Mensagem #{params[:partition]}@#{params[:offset]} republicada em " \
               "#{destination['topic']}/#{destination['partition']}@#{destination['offset']}"
      redirect_to admin_dlq_path, notice: notice, status: :see_other
    rescue DlqClient::Error, Admin::NotAllowed => error
      redirect_to admin_dlq_path, alert: "Reprocessamento não feito: #{error.message}", status: :see_other
    end

    private

    # Eventos dlq.reprocessed da marca por [partição, offset] de origem, em ordem de gravação.
    def reprocessed_by_source
      AuditEvent.where(action: DlqReprocessor::EVENT).order(:created_at, :id).group_by do |event|
        source = event.payload.dig("payload", "source") || {}
        [ source["partition"], source["offset"] ]
      end
    end
  end
end

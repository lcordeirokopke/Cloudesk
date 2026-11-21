module Admin
  # Filas da marca: lista, tela da fila com o histórico de edições, criação e edição por
  # Admin::QueueEditor. Recusas do editor voltam ao formulário com status 422 e a mensagem.
  class QueuesController < BaseController
    def index
      in_brand do
        @queues = Routing::Queue.includes(:team, :overflow_queue, :escalation_queue).order(:name).to_a
      end
    end

    def show
      in_brand do
        @queue = Routing::Queue.includes(:team, :overflow_queue, :escalation_queue).find(params[:id])
        @history = Admin::History.for_record(@queue)
      end
    end

    def new
      in_brand { load_options }
      @queue = Routing::Queue.new
    end

    def create
      queue = Admin::QueueEditor.create(brand: current_brand, attributes: queue_params, operator_name: operator_name)
      redirect_to admin_queue_path(queue), notice: "Fila criada", status: :see_other
    rescue Admin::Error => error
      in_brand { load_options }
      @queue = Routing::Queue.new(queue_params)
      render_error(:new, error)
    end

    def edit
      in_brand do
        @queue = Routing::Queue.find(params[:id])
        load_options
      end
      @expected_updated_at = Admin::Editor.version_of(@queue)
    end

    def update
      queue = Admin::QueueEditor.update(
        brand: current_brand, queue_id: params[:id], attributes: queue_params,
        expected_updated_at: params[:expected_updated_at], operator_name: operator_name
      )
      redirect_to admin_queue_path(queue), notice: "Fila atualizada", status: :see_other
    rescue Admin::Error => error
      in_brand do
        @queue = Routing::Queue.find(params[:id])
        @queue.assign_attributes(queue_params)
        load_options
      end
      @expected_updated_at = params[:expected_updated_at]
      render_error(:edit, error)
    end

    private

    def queue_params
      fields = params.require(:queue).permit(*Admin::QueueEditor::ATTRIBUTES).to_h
      %w[team_id overflow_queue_id escalation_queue_id].each { |key| fields[key] = fields[key].presence if fields.key?(key) }
      fields["name"] = fields["name"].to_s.strip if fields.key?("name")
      fields
    end

    def load_options
      @teams = Team.order(:name).to_a
      @queue_options = Routing::Queue.order(:name).to_a
    end

    def render_error(template, error)
      @errors = error.is_a?(Admin::Invalid) ? error.messages : [ error.message ]
      render template, status: :unprocessable_content
    end
  end
end

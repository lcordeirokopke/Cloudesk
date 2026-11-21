module Admin
  # Atendentes da marca: lista (IA e analistas), tela do atendente com o histórico de edições,
  # criação e edição de analistas humanos por Admin::AttendantEditor. O atendente IA é só leitura:
  # a edição dele volta à tela do atendente com aviso. Recusas do editor voltam ao formulário com
  # status 422 e a mensagem.
  class AttendantsController < BaseController
    def index
      in_brand { @attendants = Attendant.includes(:team).order(:kind, :name).to_a }
    end

    def show
      in_brand do
        @attendant = Attendant.includes(:team).find(params[:id])
        @history = Admin::History.for_record(@attendant)
      end
    end

    def new
      in_brand { load_options }
      @attendant = Attendant.new(kind: "human")
    end

    def create
      attendant = Admin::AttendantEditor.create(brand: current_brand, attributes: attendant_params,
                                                operator_name: operator_name)
      redirect_to admin_attendant_path(attendant), notice: "Analista criado", status: :see_other
    rescue Admin::Error => error
      in_brand { load_options }
      @attendant = Attendant.new(attendant_params.merge("kind" => "human"))
      render_error(:new, error)
    end

    def edit
      in_brand do
        @attendant = Attendant.find(params[:id])
        load_options
      end
      unless @attendant.kind == "human"
        return redirect_to(admin_attendant_path(@attendant), alert: "O atendente IA é só leitura")
      end

      @expected_updated_at = Admin::Editor.version_of(@attendant)
    end

    def update
      attendant = Admin::AttendantEditor.update(
        brand: current_brand, attendant_id: params[:id], attributes: attendant_params,
        expected_updated_at: params[:expected_updated_at], operator_name: operator_name
      )
      redirect_to admin_attendant_path(attendant), notice: "Analista atualizado", status: :see_other
    rescue Admin::NotAllowed => error
      redirect_to admin_attendant_path(params[:id]), alert: error.message, status: :see_other
    rescue Admin::Error => error
      in_brand do
        @attendant = Attendant.find(params[:id])
        @attendant.assign_attributes(attendant_params)
        load_options
      end
      @expected_updated_at = params[:expected_updated_at]
      render_error(:edit, error)
    end

    private

    def attendant_params
      fields = params.require(:attendant).permit(:name, :team_id, :capacity, :skills)
      { "name" => fields[:name].to_s.strip, "team_id" => fields[:team_id].presence, "capacity" => fields[:capacity],
        "skills" => split_list(fields[:skills]) }
    end

    def load_options
      @teams = Team.order(:name).to_a
    end

    def render_error(template, error)
      @errors = error.is_a?(Admin::Invalid) ? error.messages : [ error.message ]
      render template, status: :unprocessable_content
    end
  end
end

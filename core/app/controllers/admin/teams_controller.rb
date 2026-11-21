module Admin
  # Equipes da marca: lista, tela da equipe com o histórico de edições, criação e edição por
  # Admin::TeamEditor. O horário comercial vem por campos (dias da semana, início, fim e fuso) ou
  # pela opção "sem horário". Recusas do editor voltam ao formulário com status 422 e a mensagem.
  class TeamsController < BaseController
    WEEKDAYS = { 1 => "seg", 2 => "ter", 3 => "qua", 4 => "qui", 5 => "sex", 6 => "sáb", 7 => "dom" }.freeze

    helper_method :weekdays, :time_zones

    def index
      in_brand { @teams = Team.order(:name).to_a }
    end

    def show
      in_brand do
        @team = Team.find(params[:id])
        @queues = Routing::Queue.where(team_id: @team.id).order(:name).to_a
        @history = Admin::History.for_record(@team)
      end
    end

    def new
      @team = Team.new
    end

    def create
      team = Admin::TeamEditor.create(brand: current_brand, attributes: team_params, operator_name: operator_name)
      redirect_to admin_team_path(team), notice: "Equipe criada", status: :see_other
    rescue Admin::Error => error
      @team = Team.new(team_params)
      render_error(:new, error)
    end

    def edit
      in_brand { @team = Team.find(params[:id]) }
      @expected_updated_at = Admin::Editor.version_of(@team)
    end

    def update
      team = Admin::TeamEditor.update(
        brand: current_brand, team_id: params[:id], attributes: team_params,
        expected_updated_at: params[:expected_updated_at], operator_name: operator_name
      )
      redirect_to admin_team_path(team), notice: "Equipe atualizada", status: :see_other
    rescue Admin::Error => error
      in_brand do
        @team = Team.find(params[:id])
        @team.assign_attributes(team_params)
      end
      @expected_updated_at = params[:expected_updated_at]
      render_error(:edit, error)
    end

    private

    def weekdays
      WEEKDAYS
    end

    def time_zones
      ActiveSupport::TimeZone::MAPPING.values.uniq.sort
    end

    def team_params
      fields = params.require(:team).permit(:name, :skills, :hours_mode, :from, :to, :timezone, weekdays: [])
      { "name" => fields[:name].to_s.strip, "skills" => split_list(fields[:skills]),
        "business_hours" => business_hours(fields) }
    end

    # {} com "sem horário"; senão weekdays, from, to e timezone como enviados, validados pelo editor.
    def business_hours(fields)
      return {} if fields[:hours_mode] == "none"

      {
        "weekdays" => Array(fields[:weekdays]).reject(&:blank?).map { |day| Integer(day, 10, exception: false) || day },
        "from" => fields[:from].to_s, "to" => fields[:to].to_s, "timezone" => fields[:timezone].to_s
      }
    end

    def render_error(template, error)
      @errors = error.is_a?(Admin::Invalid) ? error.messages : [ error.message ]
      render template, status: :unprocessable_content
    end
  end
end

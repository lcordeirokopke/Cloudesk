module Panel
  # Login simulado do painel:
  #   GET    /panel          marcas e analistas humanos com equipe
  #   POST   /panel/session  grava a marca e o analista na sessão (analyst = "<marca>:<id>")
  #   DELETE /panel/session  limpa a sessão do painel
  class SessionsController < BaseController
    skip_before_action :require_analyst

    def index
      @analysts_by_brand = Brand.order(:slug).map do |brand|
        analysts = Tenancy.with_brand(brand) do
          Attendant.includes(:team).where(kind: "human").where.not(team_id: nil).order(:name).to_a
        end
        [ brand, analysts ]
      end
    end

    def create
      slug, attendant_id = params[:analyst].to_s.split(":", 2)
      brand = Brand.find_by(slug: slug)
      analyst = brand && attendant_id.present? && Tenancy.with_brand(brand) do
        Attendant.where(kind: "human").where.not(team_id: nil).find_by(id: attendant_id)
      end
      return redirect_to(panel_root_path, alert: "Analista não encontrado") unless analyst

      session[:panel_brand] = brand.slug
      session[:panel_attendant_id] = analyst.id
      redirect_to panel_queue_path, status: :see_other
    end

    def destroy
      session.delete(:panel_brand)
      session.delete(:panel_attendant_id)
      redirect_to panel_root_path, status: :see_other
    end
  end
end

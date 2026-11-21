module Admin
  # Escolha da marca do admin:
  #   GET    /admin          lista as marcas
  #   POST   /admin/session  grava a marca na sessão (brand = slug) e abre as regras
  #   DELETE /admin/session  limpa a marca da sessão
  class SessionsController < BaseController
    skip_before_action :require_brand

    def index
      @current_brand = Brand.find_by(slug: session[:admin_brand])
      @brands = Brand.order(:slug).to_a
    end

    def create
      brand = Brand.find_by(slug: params[:brand].to_s)
      return redirect_to(admin_root_path, alert: "Marca não encontrada") unless brand

      session[:admin_brand] = brand.slug
      redirect_to admin_rules_path, status: :see_other
    end

    def destroy
      session.delete(:admin_brand)
      redirect_to admin_root_path, status: :see_other
    end
  end
end

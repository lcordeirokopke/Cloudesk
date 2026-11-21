module Admin
  # Base do admin de filas e regras. Todo o /admin fica atrás de HTTP basic auth com ADMIN_USER e
  # ADMIN_PASSWORD; sem os dois preenchidos, o acesso é negado. O usuário do basic auth é o operador
  # (operator_name) gravado nos eventos de edição. A marca escolhida fica em session[:admin_brand], e
  # sem ela a página volta à escolha da marca. Toda leitura e escrita do domínio roda em
  # Tenancy.with_brand da marca da sessão.
  class BaseController < ApplicationController
    layout "admin"

    before_action :authenticate_admin
    before_action :require_brand

    helper_method :current_brand, :operator_name, :format_time

    rescue_from ActiveRecord::RecordNotFound do
      head :not_found
    end

    private

    attr_reader :current_brand

    def authenticate_admin
      user = ENV["ADMIN_USER"].to_s
      password = ENV["ADMIN_PASSWORD"].to_s

      authenticate_or_request_with_http_basic("Cloudesk - admin") do |given_user, given_password|
        next false if user.empty? || password.empty?

        ActiveSupport::SecurityUtils.secure_compare(given_user, user) &
          ActiveSupport::SecurityUtils.secure_compare(given_password, password)
      end
    end

    def require_brand
      @current_brand = Brand.find_by(slug: session[:admin_brand])
      redirect_to admin_root_path if @current_brand.nil?
    end

    def in_brand(&block)
      Tenancy.with_brand(@current_brand, &block)
    end

    # Usuário do basic auth da requisição.
    def operator_name
      ActionController::HttpAuthentication::Basic.user_name_and_password(request).first
    end

    # Horário em UTC, com o rótulo do fuso.
    def format_time(time)
      time && "#{time.utc.strftime('%d/%m/%Y %H:%M:%S')} UTC"
    end

    # Texto separado por vírgulas como lista, sem itens vazios.
    def split_list(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?)
    end
  end
end

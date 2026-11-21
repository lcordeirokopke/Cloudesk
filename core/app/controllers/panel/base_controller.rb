module Panel
  # Base do painel do analista. Todo o /panel fica atrás de HTTP basic auth com PANEL_USER e
  # PANEL_PASSWORD; sem os dois preenchidos, o acesso é negado. Dentro dele, o login é simulado: a
  # marca e o analista escolhidos ficam na sessão (session[:panel_brand] e
  # session[:panel_attendant_id]), e sem eles a página volta à escolha do analista. Toda leitura do
  # domínio roda em Tenancy.with_brand da marca da sessão.
  class BaseController < ApplicationController
    layout "panel"

    before_action :authenticate_panel
    before_action :require_analyst

    helper_method :current_analyst, :current_brand, :format_time, :format_duration

    private

    attr_reader :current_analyst, :current_brand

    def authenticate_panel
      user = ENV["PANEL_USER"].to_s
      password = ENV["PANEL_PASSWORD"].to_s

      authenticate_or_request_with_http_basic("Cloudesk - painel do analista") do |given_user, given_password|
        next false if user.empty? || password.empty?

        ActiveSupport::SecurityUtils.secure_compare(given_user, user) &
          ActiveSupport::SecurityUtils.secure_compare(given_password, password)
      end
    end

    def require_analyst
      @current_brand = Brand.find_by(slug: session[:panel_brand])
      @current_analyst = @current_brand && in_brand do
        Attendant.includes(:team).where(kind: "human").where.not(team_id: nil).find_by(id: session[:panel_attendant_id])
      end
      redirect_to panel_root_path if @current_analyst.nil?
    end

    def in_brand(&block)
      Tenancy.with_brand(@current_brand, &block)
    end

    def timezone
      @timezone ||= ActiveSupport::TimeZone[current_analyst&.team&.business_hours&.fetch("timezone", nil).to_s] ||
                    ActiveSupport::TimeZone["UTC"]
    end

    # Horário no fuso da equipe do analista.
    def format_time(time)
      time && time.in_time_zone(timezone).strftime("%d/%m/%Y %H:%M:%S")
    end

    # Duração em segundos como "1 h 05 min", "3 min 20 s" ou "45 s"; negativa com sinal.
    def format_duration(seconds)
      return nil if seconds.nil?

      sign = seconds.negative? ? "-" : ""
      total = seconds.abs.round
      hours, rest = total.divmod(3600)
      minutes, secs = rest.divmod(60)
      text = if hours.positive? then format("%d h %02d min", hours, minutes)
      elsif minutes.positive? then format("%d min %02d s", minutes, secs)
      else format("%d s", secs)
      end
      "#{sign}#{text}"
    end
  end
end

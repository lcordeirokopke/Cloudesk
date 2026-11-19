module Routing
  # Horário comercial de uma equipe, lido de teams.business_hours:
  #   weekdays: dias da semana ISO (1 = segunda, 7 = domingo).
  #   from, to: início e fim no formato HH:MM; o horário de início está dentro, o de fim fora.
  #   timezone: fuso do horário (nome IANA, por exemplo America/Sao_Paulo).
  # Um horário incompleto ou inválido não tem nenhum instante comercial.
  class BusinessHours
    TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/

    def initialize(config)
      @config = config.is_a?(Hash) ? config.stringify_keys : {}
    end

    def valid?
      weekdays = @config["weekdays"]
      weekdays.is_a?(Array) && weekdays.any? && weekdays.all? { |day| day.is_a?(Integer) && day.between?(1, 7) } &&
        TIME_FORMAT.match?(@config["from"].to_s) && TIME_FORMAT.match?(@config["to"].to_s) &&
        @config["from"] < @config["to"] && time_zone.present?
    end

    def open_at?(time)
      return false unless valid?

      local = time.in_time_zone(time_zone)
      clock = local.strftime("%H:%M")
      @config["weekdays"].include?(local.to_date.cwday) && clock >= @config["from"] && clock < @config["to"]
    end

    private

    def time_zone
      ActiveSupport::TimeZone[@config["timezone"].to_s] if @config["timezone"].present?
    end
  end
end

module Routing
  # Validação da condição (when) e do resultado (then) de uma regra de roteamento, na marca do bloco
  # Tenancy.with_brand corrente.
  #
  # when: chaves brand, channel, category, priority, segment, language e hours. Cada valor é um
  #       texto ou uma lista de textos. brand é o slug da marca; hours é business ou off_hours e só
  #       vale com fila de destino cuja equipe tem horário comercial válido.
  # then: queue (nome de uma fila da marca) e priority (inteiro) obrigatórios; sla_minutes (inteiro
  #       positivo) e first_attendant (ai ou human) opcionais.
  # Chaves desconhecidas são recusadas.
  class RuleDefinition
    class Invalid < StandardError; end

    WHEN_KEYS = %w[brand channel category priority segment language hours].freeze
    THEN_KEYS = %w[queue priority sla_minutes first_attendant].freeze
    HOURS = %w[business off_hours].freeze

    def self.validate!(brand:, when_clause:, then_clause:)
      errors = new(brand: brand, when_clause: when_clause, then_clause: then_clause).errors
      raise Invalid, errors.join("; ") if errors.any?

      true
    end

    # Regra genérica: when vazio ou só com brand.
    def self.generic?(when_clause)
      (when_clause.to_h.keys.map(&:to_s) - [ "brand" ]).empty?
    end

    def initialize(brand:, when_clause:, then_clause:)
      @brand = brand
      @when = when_clause
      @then = then_clause
    end

    def errors
      @errors ||= begin
        @messages = []
        validate_when
        validate_then
        @messages
      end
    end

    private

    def validate_when
      return @messages << "when deve ser um objeto" unless @when.is_a?(Hash)

      conditions = @when.stringify_keys
      unknown = conditions.keys - WHEN_KEYS
      @messages << "when tem chaves desconhecidas: #{unknown.join(', ')}" if unknown.any?

      conditions.slice(*WHEN_KEYS).each do |key, value|
        values = values_of(value)
        next @messages << "when.#{key} deve ser um texto ou uma lista de textos" if values.nil?

        @messages << "when.brand deve ser #{@brand.slug}" if key == "brand" && values != [ @brand.slug ]
        @messages << "when.hours deve ser #{HOURS.join(' ou ')}" if key == "hours" && (values - HOURS).any?
      end
    end

    def validate_then
      return @messages << "then deve ser um objeto" unless @then.is_a?(Hash)

      result = @then.stringify_keys
      unknown = result.keys - THEN_KEYS
      @messages << "then tem chaves desconhecidas: #{unknown.join(', ')}" if unknown.any?

      validate_queue(result["queue"])
      @messages << "then.priority deve ser um inteiro" unless result["priority"].is_a?(Integer)
      if result.key?("sla_minutes") && !(result["sla_minutes"].is_a?(Integer) && result["sla_minutes"].positive?)
        @messages << "then.sla_minutes deve ser um inteiro positivo"
      end
      if result.key?("first_attendant") && !Attendant::KINDS.include?(result["first_attendant"])
        @messages << "then.first_attendant deve ser #{Attendant::KINDS.join(' ou ')}"
      end
    end

    def validate_queue(name)
      return @messages << "then.queue deve ser o nome de uma fila" unless name.is_a?(String) && name.present?

      queue = Routing::Queue.find_by(name: name)
      return @messages << "then.queue não existe na marca: #{name}" if queue.nil?
      return unless @when.is_a?(Hash) && @when.stringify_keys.key?("hours")
      return if queue.team && BusinessHours.new(queue.team.business_hours).valid?

      @messages << "when.hours exige fila de destino com equipe e horário comercial válido"
    end

    # Lista de textos do valor, ou nil quando o valor não é texto nem lista não vazia de textos.
    def values_of(value)
      values = Array.wrap(value)
      return nil if values.empty? || !values.all? { |item| item.is_a?(String) && item.present? }

      values
    end
  end
end

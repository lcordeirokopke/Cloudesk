module Admin
  # Formulário estruturado de regra do admin. Converte os campos do formulário nos atributos name,
  # position, when e then do Routing::RulePublisher e monta as opções de cada dimensão do when.
  #
  # Campos (params[:rule]):
  #   name, position;
  #   when[<dimensão>][]: valores marcados de channel, category, priority, segment e language;
  #   when[hours]:        vazio (sem condição), business ou off_hours;
  #   then[queue], then[priority], then[sla_minutes] e then[first_attendant] (vazio é "da fila").
  #
  # Conversão: uma opção marcada vira texto, mais de uma vira lista e nenhuma tira a chave do when;
  # when.brand é sempre o slug da marca; SLA vazio e atendente "da fila" tiram a chave do then;
  # prioridade e posição viram inteiros quando são números. Na lista, os valores que a regra já tem
  # ficam na ordem gravada, e os novos seguem a ordem das opções: enviar o formulário sem mudança
  # devolve a mesma regra.
  #
  # As opções vêm de Routing::Dimensions.for(brand); valores gravados fora delas também aparecem,
  # marcados como fora da lista, e são preservados.
  class RuleForm
    DIMENSIONS = %w[channel category priority segment language].freeze
    THEN_FIELDS = %w[queue priority sla_minutes first_attendant].freeze

    attr_reader :brand, :rule, :name, :position, :hours, :then_values

    # Formulário preenchido com a regra (maior versão) ou vazio, para uma regra nova.
    def self.from_rule(brand:, rule: nil)
      new(brand: brand, rule: rule).tap(&:load_rule)
    end

    # Formulário preenchido com os campos enviados; rule é a maior versão lida, ou nil na criação.
    def self.from_params(brand:, params:, rule: nil)
      new(brand: brand, rule: rule).tap { |form| form.load_params(params) }
    end

    def initialize(brand:, rule: nil)
      @brand = brand
      @rule = rule
      @selected = {}
      @then_values = {}
    end

    def load_rule
      conditions = (@rule&.[]("when") || {}).stringify_keys
      result = (@rule&.[]("then") || {}).stringify_keys
      @name = @rule&.name
      @position = @rule&.position
      DIMENSIONS.each { |dimension| @selected[dimension] = Array.wrap(conditions[dimension]).map(&:to_s) }
      @hours = conditions["hours"].to_s
      @then_values = THEN_FIELDS.to_h { |field| [ field, result[field].to_s ] }
    end

    def load_params(params)
      params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      params = params.deep_stringify_keys
      conditions = params["when"].to_h
      current = (@rule&.[]("when") || {}).stringify_keys
      @name = params["name"].to_s.strip
      @position = params["position"].to_s.strip
      DIMENSIONS.each do |dimension|
        marked = Array.wrap(conditions[dimension]).map(&:to_s).reject(&:blank?).uniq
        kept = Array.wrap(current[dimension]).map(&:to_s) & marked
        @selected[dimension] = kept + (options(dimension) & (marked - kept)) + (marked - kept - options(dimension))
      end
      @hours = conditions["hours"].to_s
      @then_values = THEN_FIELDS.to_h { |field| [ field, params["then"].to_h[field].to_s.strip ] }
    end

    def selected(dimension)
      @selected.fetch(dimension)
    end

    # Opções da dimensão: as de Routing::Dimensions e, depois, os valores marcados fora delas.
    def options(dimension)
      listed = dimensions.fetch(dimension)
      listed + (Array(@selected[dimension]) - listed)
    end

    def outside?(dimension, value)
      !dimensions.fetch(dimension).include?(value)
    end

    def hours_options
      Routing::RuleDefinition::HOURS
    end

    def to_attributes
      conditions = { "brand" => brand.slug }
      DIMENSIONS.each do |dimension|
        values = selected(dimension)
        conditions[dimension] = values.one? ? values.first : values if values.any?
      end
      conditions["hours"] = @hours if @hours.present?

      result = { "queue" => @then_values["queue"].presence, "priority" => integer(@then_values["priority"]) }
      result["sla_minutes"] = integer(@then_values["sla_minutes"]) if @then_values["sla_minutes"].present?
      result["first_attendant"] = @then_values["first_attendant"] if @then_values["first_attendant"].present?

      { "name" => @name, "position" => integer(@position), "when" => conditions, "then" => result }
    end

    private

    def dimensions
      @dimensions ||= Routing::Dimensions.for(brand)
    end

    # Inteiro quando o texto é um número inteiro; senão, o próprio texto, recusado na validação.
    def integer(value)
      return value if value.is_a?(Integer)
      return nil if value.blank?

      Integer(value.to_s, 10, exception: false) || value
    end
  end
end

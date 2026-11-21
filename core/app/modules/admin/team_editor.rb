module Admin
  # Criação e edição de equipes pelo admin, com os eventos team.created e team.updated (ver
  # Admin::Editor). Roda sob a Routing::RoutingLock da marca, porque confere as regras de roteamento.
  #
  # Atributos: name, skills (lista de textos) e business_hours ({} ou weekdays, from, to e timezone,
  # no formato de Routing::BusinessHours). Recusa:
  #   - nome repetido na marca;
  #   - business_hours preenchido e inválido;
  #   - business_hours sem horário válido quando uma regra vigente com when.hours tem como destino uma
  #     fila desta equipe.
  class TeamEditor < Editor
    ATTRIBUTES = %w[name skills business_hours].freeze

    def self.update(brand:, team_id:, attributes:, expected_updated_at:, operator_name:)
      new(brand: brand, operator_name: operator_name).update(team_id, attributes, expected_updated_at)
    end

    private

    def model
      Team
    end

    def event_prefix
      "team"
    end

    def lock_routing?
      true
    end

    def prepare(team)
      team.skills = Array(team.skills).map { |skill| skill.to_s.strip }.reject(&:empty?).uniq
      team.business_hours = team.business_hours.presence || {}
    end

    def validate(team)
      messages = duplicate_name(team, "equipe")
      hours = team.business_hours
      valid = Routing::BusinessHours.new(hours).valid?
      messages << "o horário comercial é inválido" if hours.present? && !valid
      return messages if valid || team.new_record?

      messages + rules_with_hours(team)
    end

    def rules_with_hours(team)
      queue_names = Routing::Queue.where(team_id: team.id).pluck(:name)
      return [] if queue_names.empty?

      names = RoutingRule.current.where(%(jsonb_exists(routing_rules."when", 'hours')))
                         .where(%(routing_rules."then" ->> 'queue' IN (?)), queue_names).order(:position, :rule_id).pluck(:name)
      return [] if names.empty?

      [ "as regras #{names.join(', ')} usam o horário comercial desta equipe; ele precisa continuar válido" ]
    end
  end
end

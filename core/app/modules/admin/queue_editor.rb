module Admin
  # Criação e edição de filas pelo admin, com os eventos queue.created e queue.updated (ver
  # Admin::Editor). Roda sob a Routing::RoutingLock da marca, porque confere as regras de roteamento.
  #
  # Além das validações do model (Routing::Queue), recusa:
  #   - nome repetido na marca;
  #   - equipe, fila de transbordo ou fila de escalação que não existe na marca;
  #   - renomear a fila quando alguma regra, na maior versão (ativa ou não), cita o nome atual em
  #     then.queue; a mensagem lista as regras. Versões anteriores das regras não contam;
  #   - first_attendant ai quando a fila é fila de escalação de outra;
  #   - trocar a equipe quando uma regra vigente com when.hours tem esta fila como destino e a equipe
  #     nova não existe ou não tem horário comercial válido.
  # O transbordo pode formar ciclo: o Routing::Route para ao revisitar uma fila.
  class QueueEditor < Editor
    ATTRIBUTES = %w[name team_id sla_minutes capacity first_attendant overflow_queue_id escalation_queue_id].freeze

    def self.update(brand:, queue_id:, attributes:, expected_updated_at:, operator_name:)
      new(brand: brand, operator_name: operator_name).update(queue_id, attributes, expected_updated_at)
    end

    private

    def model
      Routing::Queue
    end

    def event_prefix
      "queue"
    end

    def lock_routing?
      true
    end

    def validate(queue)
      messages = duplicate_name(queue, "fila")
      messages += missing(Team, queue.team_id, "a equipe")
      messages += missing(Routing::Queue, queue.overflow_queue_id, "a fila de transbordo")
      messages += missing(Routing::Queue, queue.escalation_queue_id, "a fila de escalação")
      return messages if queue.new_record?

      messages + renamed_with_rules(queue) + escalation_target_to_ai(queue) + team_without_hours(queue)
    end

    def renamed_with_rules(queue)
      return [] unless queue.name_changed?

      names = RoutingRule.latest_versions.where(%(routing_rules."then" ->> 'queue' = ?), queue.name_was)
                         .order(:position, :rule_id).pluck(:name)
      return [] if names.empty?

      [ "a fila #{queue.name_was} é citada pelas regras #{names.join(', ')}; mude as regras antes de renomear" ]
    end

    def escalation_target_to_ai(queue)
      return [] unless queue.first_attendant_changed? && queue.first_attendant == "ai"

      names = Routing::Queue.where(escalation_queue_id: queue.id).where.not(id: queue.id).order(:name).pluck(:name)
      return [] if names.empty?

      [ "a fila é fila de escalação de #{names.join(', ')} e precisa continuar humana" ]
    end

    def team_without_hours(queue)
      return [] unless queue.team_id_changed?

      names = RoutingRule.current.where(%(jsonb_exists(routing_rules."when", 'hours')))
                         .where(%(routing_rules."then" ->> 'queue' = ?), queue.name_was).order(:position, :rule_id).pluck(:name)
      return [] if names.empty?

      team = queue.team_id && Team.find_by(id: queue.team_id)
      return [] if team && Routing::BusinessHours.new(team.business_hours).valid?

      [ "as regras #{names.join(', ')} usam o horário comercial da equipe desta fila; a equipe nova precisa ter horário comercial válido" ]
    end
  end
end

module Admin
  # Criação e edição de analistas humanos pelo admin, com os eventos attendant.created e
  # attendant.updated (ver Admin::Editor).
  #
  # Atributos: name, team_id (opcional), capacity e skills (lista de textos). O atendente criado é
  # sempre human; kind nos atributos levanta ArgumentError e a edição de um atendente ai levanta
  # Admin::NotAllowed. Equipe que não existe na marca é recusada.
  class AttendantEditor < Editor
    ATTRIBUTES = %w[name team_id capacity skills].freeze

    def self.update(brand:, attendant_id:, attributes:, expected_updated_at:, operator_name:)
      new(brand: brand, operator_name: operator_name).update(attendant_id, attributes, expected_updated_at)
    end

    private

    def model
      Attendant
    end

    def event_prefix
      "attendant"
    end

    def prepare(attendant)
      attendant.kind = "human" if attendant.new_record?
      attendant.skills = Array(attendant.skills).map { |skill| skill.to_s.strip }.reject(&:empty?).uniq
    end

    def allow_update!(attendant)
      raise NotAllowed, "o atendente IA não é editado pelo admin" unless attendant.kind == "human"
    end

    def validate(attendant)
      missing(Team, attendant.team_id, "a equipe")
    end
  end
end

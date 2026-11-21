module Admin
  # Base dos editores do admin (Admin::QueueEditor, Admin::TeamEditor e Admin::AttendantEditor).
  # Cada edição roda em um Tenancy.with_brand da marca e grava pelo Audit::Command, com
  # actor_type operator, actor_id nil e o evento <prefixo>.created ou <prefixo>.updated:
  #   target:  o registro;
  #   before:  atributos editáveis antes da edição (nil na criação);
  #   after:   atributos editáveis depois da edição;
  #   payload: operation (create ou update), diff (antes e depois de cada atributo que muda, com os
  #            valores pelo JSON, como o Routing::RulePublisher) e operator_name.
  #
  # Na edição, o registro é lido com trava (FOR UPDATE) e o updated_at precisa ser o lido por quem
  # edita (expected_updated_at, ISO 8601 com microssegundos); se mudou, levanta Admin::Stale. As
  # validações do model e as da subclasse levantam Admin::Invalid; a edição que não muda nenhum
  # atributo levanta Admin::Unchanged. Atributo fora de ATTRIBUTES levanta ArgumentError.
  #
  # A subclasse define model, event_prefix, ATTRIBUTES e, quando precisa, prepare (antes de validar),
  # validate (lista de mensagens) e lock_routing? (true quando confere regras de roteamento e precisa
  # da Routing::RoutingLock).
  class Editor
    class << self
      def create(brand:, attributes:, operator_name:)
        new(brand: brand, operator_name: operator_name).create(attributes)
      end

      def diff(before, after)
        keys = (before.keys + after.keys).uniq
        keys.each_with_object({}) do |key, changes|
          old_value = before[key].as_json
          new_value = after[key].as_json
          changes[key] = { "before" => old_value, "after" => new_value } unless old_value == new_value
        end
      end

      # updated_at em ISO 8601, UTC, com microssegundos: o valor que o formulário leva.
      def version_of(record)
        record.updated_at.utc.iso8601(6)
      end
    end

    def initialize(brand:, operator_name:)
      @brand = brand
      @operator_name = operator_name
    end

    def create(attributes)
      attributes = permit(attributes)
      Tenancy.with_brand(@brand) do
        Routing::RoutingLock.acquire(@brand) if lock_routing?
        record = model.new
        record.assign_attributes(attributes)
        prepare(record)
        check!(record)
        write(record, "create", nil)
      end
    end

    def update(id, attributes, expected_updated_at)
      attributes = permit(attributes)
      Tenancy.with_brand(@brand) do
        Routing::RoutingLock.acquire(@brand) if lock_routing?
        record = model.lock.find(id)
        allow_update!(record)
        raise Stale, "o registro mudou depois de lido; recarregue a página" unless current?(record, expected_updated_at)

        before = snapshot(record)
        record.assign_attributes(attributes)
        prepare(record)
        check!(record)
        raise Unchanged, "a edição não muda nenhum atributo" if self.class.diff(before, snapshot(record)).empty?

        write(record, "update", before)
      end
    end

    private

    def model
      raise NotImplementedError
    end

    def event_prefix
      raise NotImplementedError
    end

    def attribute_names
      self.class::ATTRIBUTES
    end

    def lock_routing?
      false
    end

    def prepare(_record); end

    def validate(_record)
      []
    end

    def allow_update!(_record); end

    def permit(attributes)
      attributes = attributes.to_h.stringify_keys
      unknown = attributes.keys - attribute_names
      raise ArgumentError, "atributos desconhecidos: #{unknown.join(', ')}" if unknown.any?

      attributes
    end

    def current?(record, expected_updated_at)
      expected = Time.iso8601(expected_updated_at.to_s)
      expected.utc.iso8601(6) == self.class.version_of(record)
    rescue ArgumentError
      false
    end

    # Validações da subclasse e do model, todas juntas.
    def check!(record)
      messages = validate(record)
      messages += record.errors.full_messages unless record.valid?
      raise Invalid, messages.uniq if messages.any?
    end

    def snapshot(record)
      attribute_names.to_h { |name| [ name, record.public_send(name) ] }.as_json
    end

    def write(record, operation, before)
      Audit::Command.call(brand: @brand, type: "#{event_prefix}.#{operation == 'create' ? 'created' : 'updated'}",
                          actor_type: "operator", actor_id: nil) do |change|
        record.save!
        after = snapshot(record)
        change.target = record
        change.before = before
        change.after = after
        change.payload = { operation: operation, diff: self.class.diff(before || {}, after), operator_name: @operator_name }
        record
      end.value
    end

    # Mensagem quando o id informado não é de um registro da marca.
    def missing(model_class, id, label)
      return [] if id.blank? || model_class.exists?(id: id)

      [ "#{label} não existe na marca" ]
    end

    def duplicate_name(record, label)
      return [] if record.name.blank?
      return [] unless record.new_record? || record.name_changed?
      return [] unless model.where(name: record.name).where.not(id: record.id).exists?

      [ "já existe #{label} com o nome #{record.name} na marca" ]
    end
  end
end

module Routing
  # Gravação das regras de roteamento. Cada operação grava uma nova versão imutável da regra e o
  # audit_event routing_rule.published (actor_type operator), com a operação, a versão anterior, a
  # nova e o diff, em uma transação na marca:
  #   create:     versão 1 de uma regra nova;
  #   update:     copia a maior versão da regra, aplica as mudanças e grava version + 1;
  #   activate:   update com active true;
  #   deactivate: update com active false.
  #
  # A gravação roda sob a trava de roteamento da marca (Routing::RoutingLock): operações simultâneas
  # da mesma marca são serializadas. Antes do commit, a marca precisa ter uma regra genérica ativa
  # (when vazio ou só com brand); sem ela, levanta NoGenericRule e nada é gravado. Uma operação que
  # não muda a regra levanta Unchanged.
  #
  # attributes:       name, position, when, then e active, com chaves texto ou símbolo.
  # operator_name:    nome do operador que editou (o usuário do basic auth do admin); quando
  #                   informado, vai ao payload do evento.
  # expected_version: em update, activate e deactivate, a versão da regra lida por quem edita;
  #                   quando informada e diferente da maior versão, levanta Stale e nada é gravado.
  module RulePublisher
    class Error < StandardError; end
    class NoGenericRule < Error; end
    class Unchanged < Error; end
    class Stale < Error; end

    ATTRIBUTES = %w[name position when then active].freeze

    class << self
      def create(brand:, attributes:, actor_id: nil, operator_name: nil)
        attributes = attributes.to_h.stringify_keys
        attributes["active"] = true unless attributes.key?("active")
        publish(brand, "create", nil, attributes, actor_id, operator_name)
      end

      def update(brand:, rule_id:, attributes:, actor_id: nil, operator_name: nil, expected_version: nil)
        Tenancy.with_brand(brand) do
          RoutingLock.acquire(brand)
          previous = RoutingRule.latest_versions.find_by!(rule_id: rule_id)
          if !expected_version.nil? && previous.version != Integer(expected_version)
            raise Stale, "a regra mudou: versão #{previous.version}, lida a #{expected_version}"
          end

          attributes = snapshot(previous).merge(attributes.to_h.stringify_keys)
          publish(brand, "update", previous, attributes, actor_id, operator_name)
        end
      end

      def activate(brand:, rule_id:, actor_id: nil, operator_name: nil, expected_version: nil)
        update(brand: brand, rule_id: rule_id, attributes: { active: true }, actor_id: actor_id,
               operator_name: operator_name, expected_version: expected_version)
      end

      def deactivate(brand:, rule_id:, actor_id: nil, operator_name: nil, expected_version: nil)
        update(brand: brand, rule_id: rule_id, attributes: { active: false }, actor_id: actor_id,
               operator_name: operator_name, expected_version: expected_version)
      end

      private

      def publish(brand, operation, previous, attributes, actor_id, operator_name)
        unknown = attributes.keys - ATTRIBUTES
        raise ArgumentError, "atributos desconhecidos: #{unknown.join(', ')}" if unknown.any?

        attributes = attributes.merge("when" => attributes["when"].as_json, "then" => attributes["then"].as_json)

        Tenancy.with_brand(brand) do
          RoutingLock.acquire(brand)
          RuleDefinition.validate!(brand: brand, when_clause: attributes["when"], then_clause: attributes["then"])
          before = previous && snapshot(previous)
          diff = diff(before || {}, attributes)
          raise Unchanged, "a operação não muda a regra" if diff.empty?

          result = Audit::Command.call(brand: brand, type: "routing_rule.published", actor_type: "operator", actor_id: actor_id) do |change|
            rule = RoutingRule.create!(
              rule_id: previous&.rule_id, version: previous ? previous.version + 1 : nil, **attributes.symbolize_keys
            )
            change.target = rule
            change.routing_rule = rule
            change.before = before
            change.after = snapshot(rule)
            change.payload = { operation: operation, rule_id: rule.rule_id, version: rule.version, diff: diff }
            change.payload[:operator_name] = operator_name if operator_name
            rule
          end

          ensure_generic_rule!(brand)
          result.value
        end
      end

      def ensure_generic_rule!(brand)
        return if RoutingRule.current.any?(&:generic?)

        raise NoGenericRule, "a marca #{brand.slug} ficaria sem regra genérica ativa"
      end

      def snapshot(rule)
        {
          "name" => rule.name, "position" => rule.position, "when" => rule["when"], "then" => rule["then"],
          "active" => rule.active
        }
      end

      # Atributos que mudam, com o valor anterior e o novo; os valores passam pelo JSON, como na coluna.
      def diff(before, after)
        ATTRIBUTES.each_with_object({}) do |key, changes|
          old_value = before[key].as_json
          new_value = after[key].as_json
          changes[key] = { "before" => old_value, "after" => new_value } unless old_value == new_value
        end
      end
    end
  end
end

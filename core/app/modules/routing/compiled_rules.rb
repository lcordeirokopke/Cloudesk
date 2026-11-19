module Routing
  # Regras vigentes de uma marca, em ordem de avaliação (position e, no empate, rule_id), como hashes
  # com id, rule_id, version, name, position, when e then. Roda dentro do Tenancy.with_brand da marca.
  #
  # Ficam no Solid Cache com a chave routing/rules/<brand_id>/<max(id) de routing_rules>. Toda
  # gravação de regra cria uma linha com id UUID v7 maior que os anteriores, e a chave muda.
  module CompiledRules
    KEY_PREFIX = "routing/rules".freeze

    def self.for(brand)
      Rails.cache.fetch(cache_key(brand)) { compile }
    end

    def self.cache_key(brand)
      "#{KEY_PREFIX}/#{brand.id}/#{RoutingRule.order(id: :desc).pick(:id)}"
    end

    def self.compile
      RoutingRule.current.order(:position, :rule_id).map do |rule|
        {
          "id" => rule.id, "rule_id" => rule.rule_id, "version" => rule.version, "name" => rule.name,
          "position" => rule.position, "when" => rule["when"], "then" => rule["then"]
        }
      end
    end
  end
end

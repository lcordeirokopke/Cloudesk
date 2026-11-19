module Routing
  # Avalia as regras em ordem (position e, no empate, rule_id) contra os fatos da conversa e devolve
  # a primeira que casa, ou nil.
  #
  # Fatos: brand, channel, category, priority (a urgência), segment, language e received_at.
  # Cada chave do when precisa casar. Valor simples compara por igualdade; lista casa com qualquer
  # item; fato vazio não casa. hours compara business ou off_hours com o received_at no horário
  # comercial da equipe da fila de destino da regra, lido por business_hours_for(nome da fila).
  class Matcher
    # rules:              hashes de Routing::CompiledRules.
    # business_hours_for: recebe o nome da fila e devolve o business_hours da equipe, ou nil.
    def initialize(rules, business_hours_for:)
      @rules = rules.sort_by { |rule| [ rule.fetch("position"), rule.fetch("rule_id") ] }
      @business_hours_for = business_hours_for
    end

    def first_match(facts)
      facts = facts.stringify_keys
      @rules.find { |rule| matches?(rule, facts) }
    end

    private

    def matches?(rule, facts)
      rule.fetch("when").all? do |key, expected|
        actual = key == "hours" ? hours_of(rule, facts["received_at"]) : facts[key]
        !actual.nil? && Array.wrap(expected).include?(actual.to_s)
      end
    end

    def hours_of(rule, received_at)
      config = @business_hours_for.call(rule.fetch("then").fetch("queue"))
      BusinessHours.new(config).open_at?(received_at) ? "business" : "off_hours"
    end
  end
end

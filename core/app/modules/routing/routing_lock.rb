module Routing
  # Trava consultiva de roteamento da marca, até o fim da transação (pg_advisory_xact_lock). Serializa
  # por marca a gravação de regras (Routing::RulePublisher) e as edições de fila e equipe do admin que
  # conferem as regras (Admin::QueueEditor e Admin::TeamEditor): a conferência contra as regras e a
  # gravação acontecem sem outra gravação de regra, fila ou equipe da marca no meio.
  module RoutingLock
    def self.acquire(brand)
      connection = ApplicationRecord.lease_connection
      key = connection.quote("routing_rules/#{brand.id}")
      connection.execute("SELECT pg_advisory_xact_lock(hashtextextended(#{key}, 0))", "Routing Lock")
    end
  end
end

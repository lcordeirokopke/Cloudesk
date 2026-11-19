# Regra de roteamento: condição (when) e resultado (then). Cada versão é uma linha imutável;
# rule_id é igual entre as versões da mesma regra. Vale a maior versão de cada regra, e ela participa
# da avaliação só quando active. As versões são gravadas por Routing::RulePublisher; a forma de when
# e then está em Routing::RuleDefinition.
class RoutingRule < ApplicationRecord
  include BrandScoped

  before_validation :assign_identity, on: :create

  validates :name, presence: true
  validates :position, numericality: { only_integer: true }
  validates :version, numericality: { only_integer: true, greater_than: 0 }

  # A maior versão de cada regra, ativa ou não.
  def self.latest_versions
    latest = unscoped.select("DISTINCT ON (routing_rules.rule_id) routing_rules.*")
                     .order(:rule_id, version: :desc)
    from(latest, :routing_rules)
  end

  # As versões vigentes: a maior versão de cada regra, filtrada por active depois da escolha.
  def self.current
    latest_versions.where(active: true)
  end

  def readonly?
    persisted?
  end

  def generic?
    Routing::RuleDefinition.generic?(self["when"])
  end

  private

  def assign_identity
    self.rule_id ||= SecureRandom.uuid_v7
    self.version ||= 1
  end
end

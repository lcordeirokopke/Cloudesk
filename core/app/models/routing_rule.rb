# Regra de roteamento: condição (when) e resultado (then). Cada versão é uma linha imutável;
# rule_id é igual entre as versões da mesma regra.
class RoutingRule < ApplicationRecord
  include BrandScoped

  before_validation :assign_identity, on: :create

  validates :name, presence: true
  validates :position, numericality: { only_integer: true }
  validates :version, numericality: { only_integer: true, greater_than: 0 }

  def readonly?
    persisted?
  end

  private

  def assign_identity
    self.rule_id ||= SecureRandom.uuid_v7
    self.version ||= 1
  end
end

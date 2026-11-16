# Registro append-only de uma decisão. O banco bloqueia UPDATE, DELETE e TRUNCATE por permissão
# e por trigger; o model recusa a alteração antes de ela chegar ao banco.
class AuditEvent < ApplicationRecord
  include BrandScoped

  belongs_to :conversation, optional: true
  belongs_to :routing_rule, optional: true

  validates :actor_type, :action, :target_type, presence: true

  def readonly?
    persisted?
  end
end

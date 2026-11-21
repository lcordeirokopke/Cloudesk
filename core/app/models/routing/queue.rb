# Fila de atendimento. O model fica em Routing porque Queue é uma classe do Ruby (Thread::Queue).
module Routing
  class Queue < ApplicationRecord
    include BrandScoped

    self.table_name = "queues"

    belongs_to :team, optional: true
    belongs_to :overflow_queue, class_name: "Routing::Queue", optional: true
    # Fila humana da mesma marca que recebe as conversas escaladas desta fila.
    belongs_to :escalation_queue, class_name: "Routing::Queue", optional: true

    validates :name, presence: true
    validates :sla_minutes, :capacity, numericality: { only_integer: true, greater_than: 0 }
    validates :first_attendant, inclusion: { in: Attendant::KINDS }
    validate :escalation_queue_is_human

    private

    def escalation_queue_is_human
      return if escalation_queue_id.nil?

      if escalation_queue_id == id
        errors.add(:escalation_queue, "deve ser diferente da própria fila")
      elsif escalation_queue.nil? || escalation_queue.first_attendant != "human"
        errors.add(:escalation_queue, "deve ser uma fila humana da marca")
      end
    end
  end
end

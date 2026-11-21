module Admin
  # Histórico de edições mostrado no admin, lido de audit_events na marca do bloco Tenancy.with_brand
  # corrente, em ordem crescente de created_at.
  module History
    # Eventos cujo alvo é o registro (fila, equipe ou atendente).
    def self.for_record(record)
      AuditEvent.where(target_type: record.class.name, target_id: record.id).order(:created_at, :id).to_a
    end

    # routing_rule.published de todas as versões de uma regra. O rule_id fica no payload do envelope
    # gravado em audit_events.payload.
    def self.for_rule(rule_id)
      AuditEvent.where(action: "routing_rule.published")
                .where("audit_events.payload -> 'payload' ->> 'rule_id' = ?", rule_id.to_s)
                .order(:created_at, :id).to_a
    end
  end
end

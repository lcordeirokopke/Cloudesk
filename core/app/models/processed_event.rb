# Evento processado: a Idempotency-Key de uma ação e o resultado da primeira execução.
class ProcessedEvent < ApplicationRecord
  include BrandScoped

  validates :idempotency_key, presence: true

  # Insere com ON CONFLICT DO NOTHING na marca corrente. Devolve true quando a linha é inserida
  # e false quando a chave existe, isto é, quando a ação foi processada.
  def self.record(idempotency_key:, result:)
    inserted = insert(
      { brand_id: Tenancy.current_brand_id, idempotency_key: idempotency_key, result: result },
      unique_by: %i[brand_id idempotency_key]
    )
    inserted.rows.any?
  end
end

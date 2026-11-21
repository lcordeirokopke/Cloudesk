# O atendimento e seu estado. As transições de estado válidas ficam só aqui, em TRANSITIONS.
# O roteamento (Routing::Route) define category, urgency, queue, priority, sla_minutes e attendant;
# queued_at é o horário em que a conversa entrou na fila humana.
class Conversation < ApplicationRecord
  include BrandScoped

  class InvalidTransition < StandardError; end

  STATES = %w[triage with_ai awaiting_human with_human resolved closed].freeze
  # Estados em que a conversa ocupa a capacidade da fila.
  OPEN_STATES = %w[with_ai awaiting_human with_human].freeze
  # Estados em que a conversa está com a operação humana: na fila de escalas ou com um analista.
  HUMAN_STATES = %w[awaiting_human with_human].freeze
  URGENCIES = %w[high normal].freeze

  TRANSITIONS = {
    "triage" => %w[with_ai awaiting_human],
    "with_ai" => %w[awaiting_human resolved triage],
    "awaiting_human" => %w[with_human],
    "with_human" => %w[resolved],
    "resolved" => %w[triage closed],
    "closed" => []
  }.freeze

  belongs_to :contact
  belongs_to :queue, class_name: "Routing::Queue", optional: true
  belongs_to :attendant, optional: true
  has_many :messages
  has_many :handoffs

  validates :channel, inclusion: { in: ContactIdentity::CHANNELS }
  validates :state, inclusion: { in: STATES }
  validates :urgency, inclusion: { in: URGENCIES }, allow_nil: true
  validate :starts_in_triage, on: :create
  validate :transition_is_allowed, on: :update, if: :will_save_change_to_state?

  def self.transition_allowed?(from, to)
    TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
  end

  def transition_to!(new_state)
    unless self.class.transition_allowed?(state, new_state)
      raise InvalidTransition, "transição inválida: #{state} -> #{new_state}"
    end

    update!(state: new_state)
  end

  # Grava uma mensagem com a próxima sequência da conversa. O UPDATE bloqueia a linha da conversa
  # até o commit, o que serializa escritas concorrentes na mesma conversa.
  # O savepoint desfaz o incremento quando a mensagem não é gravada.
  def append_message!(attributes)
    previous_sequence = last_sequence

    transaction(requires_new: true) do
      sequence = next_sequence!
      messages.create!(attributes.merge(brand_id: brand_id, sequence: sequence))
    end
  rescue StandardError
    self.last_sequence = previous_sequence
    clear_attribute_changes([ :last_sequence ])
    raise
  end

  private

  def next_sequence!
    sql = self.class.sanitize_sql_array([ <<~SQL.squish, id ])
      UPDATE conversations
         SET last_sequence = last_sequence + 1
       WHERE id = ?
      RETURNING last_sequence
    SQL
    row = self.class.lease_connection.exec_query(sql, "Conversation Next Sequence").first
    raise ActiveRecord::RecordNotFound, "conversa #{id} não encontrada na marca corrente" unless row

    self.last_sequence = row["last_sequence"]
    clear_attribute_changes([ :last_sequence ])
    last_sequence
  end

  def starts_in_triage
    errors.add(:state, "deve ser triage na abertura") unless state == "triage"
  end

  def transition_is_allowed
    return if self.class.transition_allowed?(state_in_database, state)

    errors.add(:state, "transição inválida: #{state_in_database} -> #{state}")
  end
end

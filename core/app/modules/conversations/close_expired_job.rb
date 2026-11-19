module Conversations
  # Varredura recorrente do prazo de reabertura: em cada marca, as conversas resolved com resolved_at
  # anterior a agora menos brands.reopen_window_minutes passam a closed (conversation.closed).
  # Lê em lotes com FOR UPDATE SKIP LOCKED: duas varreduras simultâneas não pegam a mesma conversa,
  # e a conversa que o Intake está reabrindo fica de fora. O Intake também confere o prazo na
  # entrada, o que mantém a regra correta mesmo com atraso desta varredura.
  class CloseExpiredJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100
    REASON = "prazo de reabertura vencido".freeze

    def perform
      Brand.find_each { |brand| close_expired(brand) }
    end

    private

    def close_expired(brand)
      cutoff = Time.current - brand.reopen_window

      loop do
        closed = Tenancy.with_brand(brand) do
          batch = Conversation.where(state: "resolved").where(resolved_at: ...cutoff)
                              .order(:resolved_at).limit(BATCH_SIZE).lock("FOR UPDATE SKIP LOCKED").to_a
          batch.each { |conversation| close(brand, conversation) }
          batch.size
        end
        break if closed < BATCH_SIZE
      end
    end

    def close(brand, conversation)
      Audit::Command.call(brand: brand, type: "conversation.closed", actor_type: "system", reason: REASON) do |change|
        change.before = { state: conversation.state }
        conversation.transition_to!("closed")
        change.after = { state: conversation.state }
        change.target = conversation
        change.conversation = conversation
        conversation
      end
    end
  end
end

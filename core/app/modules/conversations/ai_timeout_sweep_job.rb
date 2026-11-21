module Conversations
  # Varredura recorrente do timeout do agente, a cada 15 segundos no jobs-default. Não existe timer
  # por mensagem. Em cada marca, olha as conversas em with_ai pela última mensagem do lojista (a de
  # maior sequence) e faz duas passagens, nesta ordem:
  #   1. escalação: a última mensagem do lojista tem conversations.sla_minutes ou mais e nenhuma
  #      mensagem da IA veio depois dela. A conversa é escalada (Conversations::Escalate) com motivo
  #      ai_timeout, resumo do sistema no locale da marca, contexto vazio e ator system;
  #   2. espera: a última mensagem do lojista tem metade do SLA ou mais e nenhuma mensagem da IA ou
  #      do sistema veio depois dela. O sistema responde com a mensagem de espera no locale da
  #      marca, uma vez por mensagem do lojista. A espera não reinicia o prazo da escalação.
  #
  # As conversas são lidas em lotes com FOR UPDATE OF conversations SKIP LOCKED: a conversa travada
  # por uma ação do agente, por uma mensagem de entrada ou por outra varredura fica para a próxima
  # execução. Depois da trava, as condições são conferidas de novo, porque a reavaliação do FOR
  # UPDATE não cobre as subconsultas em messages. Um categorize aceito não grava mensagem e não
  # conta como resposta.
  class AiTimeoutSweepJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100
    ESCALATION_REASON = "ai_timeout".freeze
    WAIT_REASON = "ai_timeout_wait".freeze

    # Autores cuja mensagem, depois da última do lojista, encerra cada passagem.
    ANSWERED_BY = { escalation: %w[ai], wait: %w[ai system] }.freeze
    # Fração do SLA, em segundos por minuto de SLA, de cada passagem.
    SECONDS_PER_SLA_MINUTE = { escalation: 60, wait: 30 }.freeze

    def perform
      Brand.find_each do |brand|
        sweep(brand, :escalation)
        sweep(brand, :wait)
      end
    end

    private

    def sweep(brand, pass)
      loop do
        size = Tenancy.with_brand(brand) do
          batch = due(pass)
          batch.each { |conversation| handle(brand, conversation, pass) }
          batch.size
        end
        break if size < BATCH_SIZE
      end
    end

    # Conversas vencidas na passagem, travadas, com a sequence e o horário da última mensagem do
    # lojista.
    def due(pass)
      Conversation.select("conversations.*, last_customer.sequence AS last_customer_sequence")
                  .joins(Arel.sql(<<~SQL.squish))
                    CROSS JOIN LATERAL (
                      SELECT messages.sequence, messages.created_at
                        FROM messages
                       WHERE messages.brand_id = conversations.brand_id
                         AND messages.conversation_id = conversations.id
                         AND messages.author = 'customer'
                       ORDER BY messages.sequence DESC
                       LIMIT 1
                    ) last_customer
                  SQL
                  .where(state: "with_ai")
                  .where.not(sla_minutes: nil)
                  .where("last_customer.created_at + conversations.sla_minutes * make_interval(secs => ?) <= ?",
                         SECONDS_PER_SLA_MINUTE.fetch(pass), Time.current)
                  .where(<<~SQL.squish, ANSWERED_BY.fetch(pass))
                    NOT EXISTS (
                      SELECT 1 FROM messages answers
                       WHERE answers.brand_id = conversations.brand_id
                         AND answers.conversation_id = conversations.id
                         AND answers.author IN (?)
                         AND answers.sequence > last_customer.sequence
                    )
                  SQL
                  .order("last_customer.created_at")
                  .limit(BATCH_SIZE)
                  .lock("FOR UPDATE OF conversations SKIP LOCKED")
                  .to_a
    end

    def handle(brand, conversation, pass)
      last_customer = Message.where(conversation_id: conversation.id, author: "customer").order(sequence: :desc).first
      return unless due?(conversation, last_customer, pass)

      if pass == :escalation
        escalate(brand, conversation)
      else
        wait(brand, conversation, last_customer)
      end
    end

    # Conferência depois da trava, com o estado confirmado da conversa e das mensagens.
    def due?(conversation, last_customer, pass)
      return false unless conversation.state == "with_ai" && conversation.sla_minutes && last_customer

      deadline = last_customer.created_at + (conversation.sla_minutes * SECONDS_PER_SLA_MINUTE.fetch(pass)).seconds
      return false if deadline > Time.current

      !Message.where(conversation_id: conversation.id, author: ANSWERED_BY.fetch(pass))
              .where("sequence > ?", last_customer.sequence).exists?
    end

    def escalate(brand, conversation)
      Escalate.call(
        conversation: conversation, reason: ESCALATION_REASON,
        summary: I18n.t("conversations.ai_timeout.summary", minutes: conversation.sla_minutes, locale: brand.locale),
        context: {}, actor_type: "system"
      )
    end

    def wait(brand, conversation, last_customer)
      Outbound.append!(
        conversation: conversation, author: "system",
        text: I18n.t("conversations.ai_timeout.wait_message", locale: brand.locale),
        in_reply_to_sequence: last_customer.sequence, reason: WAIT_REASON
      )
    end
  end
end

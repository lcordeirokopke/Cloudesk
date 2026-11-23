module Observability
  # Gauges do domínio para o cockpit operacional, por marca, em Tenancy.with_brand. O label brand é
  # o slug da marca e o label queue é o nome da fila (none sem fila). Só lê, sem travas.
  #
  #   cloudesk_conversations_open{brand,queue,state}  conversas em with_ai, awaiting_human e with_human
  #   cloudesk_conversations_sla{brand,queue,level}   fração do SLA consumida: at_risk de 0,5 até
  #                                                   menos de 1, breached a partir de 1. Em with_ai, o
  #                                                   tempo desde a última mensagem do lojista sem
  #                                                   mensagem ai depois dela; em awaiting_human, o
  #                                                   tempo desde queued_at
  #   cloudesk_conversations_resolved_24h{brand}       conversation.resolved das últimas 24 h
  #   cloudesk_conversations_resolved_by_ai_24h{brand} os de ator ai sem handoff da conversa criado
  #                                                   antes do evento (contenção da IA)
  #   cloudesk_handoffs_24h{brand,reason}             handoffs das últimas 24 h por motivo (Pareto)
  class CockpitReader
    OPEN_STATES = %w[with_ai awaiting_human with_human].freeze
    AT_RISK = 0.5
    WINDOW = 24.hours
    NO_QUEUE = "none".freeze

    def initialize(registry:)
      @registry = registry
    end

    def collect
      values = Hash.new { |hash, name| hash[name] = {} }
      now = Time.current

      Brand.order(:slug).each do |brand|
        Tenancy.with_brand(brand) { collect_brand(brand, now, values) }
      end

      %i[cloudesk_conversations_open cloudesk_conversations_sla cloudesk_conversations_resolved_24h
         cloudesk_conversations_resolved_by_ai_24h cloudesk_handoffs_24h].each do |name|
        @registry.replace(name, values[name])
      end
    end

    private

    def collect_brand(brand, now, values)
      queue_names = Routing::Queue.pluck(:id, :name).to_h
      queue_label = ->(queue_id) { queue_names.fetch(queue_id, NO_QUEUE) }
      slug = brand.slug

      Conversation.where(state: OPEN_STATES).group(:queue_id, :state).count.each do |(queue_id, state), count|
        labels = { brand: slug, queue: queue_label.call(queue_id), state: state }
        values[:cloudesk_conversations_open][labels] = values[:cloudesk_conversations_open].fetch(labels, 0) + count
      end

      sla_levels(now).each do |(queue_id, level), count|
        labels = { brand: slug, queue: queue_label.call(queue_id), level: level }
        values[:cloudesk_conversations_sla][labels] = values[:cloudesk_conversations_sla].fetch(labels, 0) + count
      end

      resolved = resolved_events(now)
      values[:cloudesk_conversations_resolved_24h][{ brand: slug }] = resolved.count
      values[:cloudesk_conversations_resolved_by_ai_24h][{ brand: slug }] = resolved_by_ai(resolved).count

      Handoff.where("created_at >= ?", now - WINDOW).group(:reason).count.each do |reason, count|
        values[:cloudesk_handoffs_24h][{ brand: slug, reason: reason }] = count
      end
    end

    # Contagem por [queue_id, level] das conversas com 50% ou mais do SLA consumido.
    def sla_levels(now)
      (with_ai_waiting + awaiting_human).each_with_object(Hash.new(0)) do |(queue_id, sla_minutes, since), counts|
        fraction = (now - since) / (sla_minutes * 60.0)
        next if fraction < AT_RISK

        counts[[ queue_id, fraction >= 1 ? "breached" : "at_risk" ]] += 1
      end
    end

    # [queue_id, sla_minutes, horário da última mensagem do lojista] das conversas em with_ai sem
    # mensagem ai depois da última mensagem do lojista.
    def with_ai_waiting
      Conversation.joins(Arel.sql(<<~SQL.squish))
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
                  .where(<<~SQL.squish)
                    NOT EXISTS (
                      SELECT 1 FROM messages answers
                       WHERE answers.brand_id = conversations.brand_id
                         AND answers.conversation_id = conversations.id
                         AND answers.author = 'ai'
                         AND answers.sequence > last_customer.sequence
                    )
                  SQL
                  .pluck(:queue_id, :sla_minutes, Arel.sql("last_customer.created_at"))
    end

    def awaiting_human
      Conversation.where(state: "awaiting_human").where.not(sla_minutes: nil).where.not(queued_at: nil)
                  .pluck(:queue_id, :sla_minutes, :queued_at)
    end

    # O limite inferior pelo id (UUID v7, gerado no horário da inserção) faz a leitura usar o índice
    # (brand_id, id); a condição em created_at define a janela.
    def resolved_events(now)
      since = now - WINDOW
      AuditEvent.where(action: "conversation.resolved")
                .where("id >= ?", uuid_v7_floor(since - 1.minute))
                .where("created_at >= ?", since)
    end

    def resolved_by_ai(resolved)
      resolved.where(actor_type: "ai").where(<<~SQL.squish)
        NOT EXISTS (
          SELECT 1 FROM handoffs
           WHERE handoffs.brand_id = audit_events.brand_id
             AND handoffs.conversation_id = audit_events.conversation_id
             AND handoffs.created_at < audit_events.created_at
        )
      SQL
    end

    # Menor UUID v7 do instante informado: os 48 bits do horário em milissegundos e o restante zerado,
    # com a versão 7 e a variante RFC 9562.
    def uuid_v7_floor(time)
      hex = format("%012x", (time.to_r * 1000).floor)
      "#{hex[0, 8]}-#{hex[8, 4]}-7000-8000-000000000000"
    end
  end
end

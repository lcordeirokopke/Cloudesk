module Observability
  # Latência por salto e ponta a ponta das respostas da IA, lida de audit_events por cursor. Só lê;
  # nada é gravado no banco.
  #
  # Cada marca tem um cursor, o id do último message.delivered lido. O cursor começa no instante em
  # que o leitor é criado (um UUID v7 desse instante), sem leitura retroativa; a marca que aparece
  # depois recebe o cursor quando é vista pela primeira vez. A cada coleta, em Tenancy.with_brand da
  # marca, o leitor lê em lotes os message.delivered com id maior que o cursor e criados há mais de
  # SETTLE_SECONDS: o id UUID v7 é gerado na inserção, e uma transação com id menor pode confirmar
  # depois de outra com id maior; as transações do Core são curtas e a margem cobre a diferença.
  #
  # Para cada entrega, conta só a primeira entrega de uma mensagem ai. O início é o received_at do
  # message.created da mensagem do lojista respondida (in_reply_to_sequence da resposta) e o fim é o
  # delivered_at da entrega. Com o agent.reply do mesmo trace_id cujo inbound_event_id é o event_id
  # desse message.created, observa os seis saltos e a ponta a ponta descontada da latência
  # artificial (model.parameters.artificial_latency_ms); sem o agent.reply, só a ponta a ponta
  # bruta; sem model, não observa a descontada. Valor negativo (relógios) é observado como 0.
  #
  #   core_to_broker   broker_received_at menos o received_at do message.created do lojista
  #   broker_to_kafka  kafka_appended_at menos broker_received_at
  #   kafka_to_agent   agent_consumed_at menos kafka_appended_at
  #   agent            agent_published_at menos agent_consumed_at (inclui a latência artificial)
  #   agent_to_core    received_at do agent.reply menos agent_published_at
  #   core_to_channel  delivered_at menos received_at do agent.reply
  class LatencyReader
    SETTLE_SECONDS = 10
    BATCH_SIZE = 1000
    HOPS = %w[core_to_broker broker_to_kafka kafka_to_agent agent agent_to_core core_to_channel].freeze

    def initialize(registry:, logger: Rails.logger)
      @registry = registry
      @logger = logger
      @boot_cursor = SecureRandom.uuid_v7
      @cursors = {}
    end

    def collect
      Brand.find_each { |brand| collect_brand(brand) }
    end

    private

    def collect_brand(brand)
      @cursors[brand.id] ||= @boot_cursor

      loop do
        size = Tenancy.with_brand(brand) do
          batch = AuditEvent.where(action: "message.delivered")
                            .where("id > ?", @cursors[brand.id])
                            .where("created_at < ?", SETTLE_SECONDS.seconds.ago)
                            .order(:id).limit(BATCH_SIZE).to_a
          observe_batch(batch)
          @cursors[brand.id] = batch.last.id if batch.any?
          batch.size
        end
        break if size < BATCH_SIZE
      end
    end

    def observe_batch(deliveries)
      return if deliveries.empty?

      conversation_ids = deliveries.map(&:conversation_id).uniq
      ai_messages = Message.where(id: deliveries.map(&:target_id), author: "ai").index_by(&:id)
      deliveries = deliveries.select { |event| ai_messages.key?(event.target_id) }
      return if deliveries.empty?

      first_delivery = first_deliveries(conversation_ids, ai_messages.keys)
      replies = created_events(conversation_ids, ai_messages.keys)
      customers = customer_messages(conversation_ids, replies.values)
      customer_events = created_events(conversation_ids, customers.values.map(&:id))
      actions = agent_replies(customer_events.values)

      deliveries.each do |delivery|
        next unless first_delivery[delivery.target_id] == delivery.id

        reply_event = replies[delivery.target_id] or next
        customer = customers[[ reply_event.conversation_id, reply_event.payload.dig("payload", "in_reply_to_sequence") ]] or next
        customer_event = customer_events[customer.id] or next

        observe(delivery, customer_event, actions[customer_event.event_id])
      end
    end

    # Menor id de message.delivered de cada mensagem: a entrega repetida conta uma vez.
    def first_deliveries(conversation_ids, message_ids)
      AuditEvent.where(action: "message.delivered", conversation_id: conversation_ids, target_id: message_ids)
                .pluck(:target_id, :id)
                .group_by(&:first)
                .transform_values { |pairs| pairs.map(&:last).min }
    end

    # message.created de cada mensagem, por id da mensagem.
    def created_events(conversation_ids, message_ids)
      AuditEvent.where(action: "message.created", target_type: "Message", conversation_id: conversation_ids,
                       target_id: message_ids)
                .index_by(&:target_id)
    end

    # Mensagens do lojista respondidas, por [conversation_id, sequence].
    def customer_messages(conversation_ids, reply_events)
      sequences = reply_events.map { |event| event.payload.dig("payload", "in_reply_to_sequence") }.compact.uniq
      Message.where(conversation_id: conversation_ids, author: "customer", sequence: sequences)
             .index_by { |message| [ message.conversation_id, message.sequence ] }
    end

    # agent.reply de cada message.created do lojista, por event_id do message.created.
    def agent_replies(customer_events)
      by_event_id = customer_events.index_by(&:event_id)
      AuditEvent.where(action: "agent.reply", trace_id: customer_events.map(&:trace_id).uniq).each_with_object({}) do |event, found|
        inbound = event.payload.dig("payload", "action", "inbound_event_id")
        customer_event = by_event_id[inbound]
        found[inbound] ||= event if customer_event && customer_event.trace_id == event.trace_id
      end
    end

    def observe(delivery, customer_event, agent_reply)
      channel = delivery.payload.dig("payload", "channel")
      started_at = time(customer_event.payload["received_at"])
      delivered_at = time(delivery.payload.dig("payload", "delivered_at"))
      raw = elapsed(started_at, delivered_at, "end_to_end_raw", delivery)

      histogram(:cloudesk_end_to_end_raw_latency_seconds, raw, channel: channel)
      return if agent_reply.nil?

      action = agent_reply.payload.dig("payload", "action")
      stamps = action.fetch("timestamps").transform_values { |value| time(value) }
      action_received_at = time(agent_reply.payload["received_at"])
      points = [ started_at, stamps["broker_received_at"], stamps["kafka_appended_at"], stamps["agent_consumed_at"],
                 stamps["agent_published_at"], action_received_at, delivered_at ]

      HOPS.each_with_index do |hop, index|
        histogram(:cloudesk_hop_latency_seconds, elapsed(points[index], points[index + 1], hop, delivery),
                  hop: hop, channel: channel)
      end

      artificial_ms = action.dig("model", "parameters", "artificial_latency_ms")
      return unless artificial_ms.is_a?(Numeric)

      discounted = raw - (artificial_ms / 1000.0)
      histogram(:cloudesk_end_to_end_latency_seconds, non_negative(discounted, "end_to_end", delivery), channel: channel)
    end

    def elapsed(from, to, name, delivery)
      non_negative(to - from, name, delivery)
    end

    def non_negative(seconds, name, delivery)
      return seconds unless seconds.negative?

      @logger.warn("[observability] #{name} negativo (#{seconds.round(3)} s) na entrega #{delivery.event_id}; observado como 0")
      0
    end

    def histogram(name, seconds, **labels)
      @registry[name].observe(seconds, labels: labels.transform_values(&:to_s))
    end

    def time(value)
      Time.iso8601(value)
    end
  end
end

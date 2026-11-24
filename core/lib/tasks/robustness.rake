# Conferência de duplicação e cobertura no Core depois de uma rodada com réplicas ou com falhas
# injetadas. Só leitura: em Tenancy.with_brand de cada marca, olha as mensagens do lojista criadas a
# partir de SINCE e não grava nada. Imprime uma linha ok ou falhou por expectativa, com o valor
# encontrado, e termina com código 1 quando alguma falha.
#   bin/rails robustness:check SINCE=<ISO 8601>
#
# | Expectativa | Como confere |
# | - | - |
# | Nenhuma resposta ai duplicada | no máximo um agent.reply por inbound_event_id (o event_id do message.created do lojista) |
# | Nenhuma entrega duplicada | no máximo um message.delivered por mensagem ai ou system |
# | Nenhuma idempotência repetida | no máximo um evento de ação aceita (agent.reply, agent.escalate, agent.categorize, agent.resolve) por idempotency_key |
# | Mensagens sem ação | toda mensagem do lojista enviada ao agente tem ação aceita, stale ou rejected da conversa com based_on_sequence maior ou igual à sequence dela, ou escalação ai_timeout depois dela |
#
# Mensagem enviada ao agente: o message.created dela enfileirou o Agents::WebhookDeliveryJob (job com
# o event_id em solid_queue_jobs) e não tem webhook.skipped. O Solid Queue guarda os jobs concluídos
# (preserve_finished_jobs); em produção, a tarefa clear_solid_queue_finished_jobs apaga os concluídos
# há mais de 1 dia, e a conferência vale para um SINCE dentro desse prazo.
module RobustnessCheck
  ACCEPTED_ACTIONS = %w[agent.reply agent.escalate agent.categorize agent.resolve].freeze
  ACTION_EVENTS = (ACCEPTED_ACTIONS + %w[agent.action.stale agent.action.rejected]).freeze
  LISTED = 10

  Result = Struct.new(:label, :ok, :found)

  module_function

  def run(since:)
    raise ArgumentError, "informe SINCE=<ISO 8601>" if since.to_s.strip.empty?

    start = Time.iso8601(since.to_s.strip)
    sent_event_ids = sent_to_agent(start)
    totals = Hash.new { |hash, key| hash[key] = [] }

    Brand.order(:slug).each do |brand|
      Tenancy.with_brand(brand) do
        totals[:duplicated_replies].concat(duplicated_replies(start))
        totals[:duplicated_deliveries].concat(duplicated_deliveries(start))
        totals[:repeated_keys].concat(repeated_keys(start))
        totals[:without_action].concat(without_action(start, sent_event_ids).map { |id| "#{brand.slug}:#{id}" })
      end
    end

    [
      result("nenhuma resposta ai duplicada", totals[:duplicated_replies]),
      result("nenhuma entrega duplicada", totals[:duplicated_deliveries]),
      result("nenhuma idempotência repetida", totals[:repeated_keys]),
      result("mensagens sem ação", totals[:without_action])
    ]
  end

  # Imprime uma linha por resultado; devolve true quando todos passam.
  def report(results, io = $stdout)
    results.each { |result| io.puts "#{(result.ok ? 'ok' : 'falhou').ljust(7)} #{result.label}: #{result.found}" }
    results.all?(&:ok)
  end

  def result(label, items)
    found = items.empty? ? "0" : "#{items.size} (#{items.first(LISTED).join(', ')}#{items.size > LISTED ? ', ...' : ''})"
    Result.new(label, items.empty?, found)
  end

  # event_id dos message.created que enfileiraram o webhook ao Broker desde start.
  def sent_to_agent(start)
    SolidQueue::Job.where(class_name: "Agents::WebhookDeliveryJob").where(created_at: start..)
                   .pluck(:arguments)
                   .filter_map do |arguments|
                     arguments = JSON.parse(arguments) if arguments.is_a?(String)
                     arguments.dig("arguments", 0, "event_id")
                   end
                   .to_set
  end

  def customer_messages(start)
    Message.where(author: "customer").where(created_at: start..)
  end

  def message_created(start)
    AuditEvent.where(action: "message.created", target_type: "Message", target_id: customer_messages(start).select(:id))
  end

  # inbound_event_id com mais de um agent.reply.
  def duplicated_replies(start)
    AuditEvent.where(action: "agent.reply")
              .where("payload #>> '{payload,action,inbound_event_id}' IN (?)", message_created(start).select("event_id::text"))
              .group(Arel.sql("payload #>> '{payload,action,inbound_event_id}'"))
              .having("count(*) > 1").count.keys
  end

  # Mensagens ai ou system com mais de um message.delivered.
  def duplicated_deliveries(start)
    answers = Message.where(author: %w[ai system]).where(created_at: start..).select(:id)
    AuditEvent.where(action: "message.delivered", target_type: "Message", target_id: answers)
              .group(:target_id).having("count(*) > 1").count.keys
  end

  # idempotency_key com mais de um evento de ação aceita.
  def repeated_keys(start)
    AuditEvent.where(action: ACCEPTED_ACTIONS).where(created_at: start..)
              .group(Arel.sql("payload #>> '{payload,idempotency_key}'"))
              .having("count(*) > 1").count.keys
  end

  # Ids das mensagens do lojista enviadas ao agente sem ação que as cubra nem escalação ai_timeout
  # depois delas.
  def without_action(start, sent_event_ids)
    created = message_created(start).pluck(:event_id, :target_id).select { |event_id, _| sent_event_ids.include?(event_id) }
    skipped = AuditEvent.where(action: "webhook.skipped", target_id: created.map(&:last)).pluck(:target_id).to_set
    message_ids = created.map(&:last).reject { |id| skipped.include?(id) }
    return [] if message_ids.empty?

    messages = Message.where(id: message_ids).to_a
    conversation_ids = messages.map(&:conversation_id).uniq
    covered_up_to = AuditEvent.where(action: ACTION_EVENTS, conversation_id: conversation_ids)
                              .group(:conversation_id)
                              .maximum(Arel.sql("(payload #>> '{payload,action,based_on_sequence}')::integer"))
    timeouts = AuditEvent.where(action: "conversation.escalated", reason: Conversations::AiTimeoutSweepJob::ESCALATION_REASON,
                                conversation_id: conversation_ids)
                         .group(:conversation_id).maximum(:created_at)

    messages.reject do |message|
      covered_up_to.fetch(message.conversation_id, 0).to_i >= message.sequence ||
        (timeouts[message.conversation_id] && timeouts[message.conversation_id] >= message.created_at)
    end.map(&:id).sort
  end
end

namespace :robustness do
  desc "Confere no Core respostas, entregas e idempotência sem duplicação e mensagens sem ação desde SINCE"
  task check: :environment do
    exit(1) unless RobustnessCheck.report(RobustnessCheck.run(since: ENV["SINCE"]))
  end
end

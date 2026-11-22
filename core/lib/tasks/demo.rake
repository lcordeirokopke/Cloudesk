# Conferência no Core dos cenários de demonstração do simulador de canais
# (channel-simulator scenario <nome>). O simulador confere o que chega ao canal e imprime este
# comando; a task confere o que o lojista não vê: estado da conversa, handoff e eventos de auditoria.
# Só leitura: acha cada mensagem pela (channel, external_id), chega às conversas e ao lojista e não
# grava nada. Imprime uma linha ok ou falhou por expectativa, com o valor encontrado, e termina com
# código 1 quando alguma falha.
#   bin/rails demo:check SCENARIO=<nome> BRAND=<slug> CHANNEL=<canal> EXTERNAL_IDS=<id1,id2,...>
#
# | Cenário | Expectativas |
# | - | - |
# | reply | conversa with_ai; um agent.reply; message.delivered da resposta |
# | handoff | awaiting_human na fila de escalação da fila de origem (ou na mesma, sem ela); Handoff intencao_nao_identificada com confiança 0,2 explicada em attempts; conversation.escalated |
# | reopen | uma conversa com conversation.resolved e depois conversation.reopened; with_ai; dois agent.reply |
# | memory | EXTERNAL_IDS das duas partes; duas conversas do lojista, a primeira closed e a segunda with_ai; customer_memory; agent.reply da segunda com o prefixo da memória |
# | failure-duplicate | um agent.reply; uma linha em processed_events para a chave |
# | failure-stale | SLA de 1 min; agent.action.stale; conversation.escalated ai_timeout; awaiting_human |
# | failure-drop | SLA de 1 min; nenhum evento de ação do agente; mensagem system ai_timeout_wait; conversation.escalated ai_timeout |
# | failure-delay | SLA de 1 min; mensagem system ai_timeout_wait antes do agent.reply; with_ai; nenhum conversation.escalated |
module DemoCheck
  SCENARIOS = %w[reply handoff reopen memory failure-duplicate failure-stale failure-drop failure-delay].freeze
  TIMEOUT_SCENARIOS = %w[failure-stale failure-drop failure-delay].freeze
  CHANNELS = %w[whatsapp chat email].freeze
  ACTION_EVENTS = %w[agent.reply agent.escalate agent.categorize agent.resolve agent.action.stale
                     agent.action.rejected].freeze
  # Início do reply do agente mock quando a memória do lojista tem conversa do mesmo assunto.
  MEMORY_PREFIX = { "pt-BR" => "Vi que você já falou com a gente sobre ", "en-US" => "I see you contacted us about " }.freeze

  Result = Struct.new(:label, :ok, :found)

  module_function

  # Motivos da varredura do timeout, lidos depois da carga do app.
  def wait_reason
    Conversations::AiTimeoutSweepJob::WAIT_REASON
  end

  def timeout_reason
    Conversations::AiTimeoutSweepJob::ESCALATION_REASON
  end

  # Resultados das expectativas do cenário, na ordem.
  def run(scenario:, brand:, channel:, external_ids:)
    raise ArgumentError, "cenário desconhecido: #{scenario.inspect} (SCENARIO: #{SCENARIOS.join(', ')})" unless SCENARIOS.include?(scenario)
    raise ArgumentError, "canal desconhecido: #{channel.inspect} (CHANNEL)" unless CHANNELS.include?(channel)

    ids = external_ids.to_s.split(",").map(&:strip).reject(&:empty?)
    raise ArgumentError, "informe EXTERNAL_IDS=<id1,id2,...>" if ids.empty?

    record = Brand.find_by(slug: brand.to_s) || raise(ArgumentError, "marca #{brand.inspect} não encontrada (BRAND)")
    Tenancy.with_brand(record) { Check.new(record, scenario, channel, ids).results }
  end

  # Imprime uma linha por resultado; devolve true quando todos passam.
  def report(results, io = $stdout)
    results.each { |result| io.puts "#{(result.ok ? 'ok' : 'falhou').ljust(7)} #{result.label}: #{result.found}" }
    results.all?(&:ok)
  end

  class Check
    def initialize(brand, scenario, channel, external_ids)
      @brand = brand
      @scenario = scenario
      @channel = channel
      @external_ids = external_ids
      @results = []
    end

    def results
      @messages = @external_ids.map { |id| Message.find_by(channel: @channel, external_id: id) }
      @external_ids.zip(@messages).each do |id, message|
        expect("mensagem #{id}", message.present?, message ? "conversa #{message.conversation_id}" : "não encontrada")
      end
      return @results unless @messages.all?

      @conversations = @messages.map(&:conversation_id).uniq.map { |id| Conversation.find(id) }
      if DemoCheck::TIMEOUT_SCENARIOS.include?(@scenario)
        conversation = single_conversation
        return @results unless conversation

        timeout_sla(conversation)
      end
      send(@scenario.tr("-", "_"))
      @results
    end

    private

    def expect(label, ok, found)
      @results << Result.new(label, ok ? true : false, found)
      ok
    end

    def single_conversation
      conversation = @conversations.first
      expect("uma conversa", @conversations.size == 1, @conversations.map(&:id).join(", ")) && conversation
    end

    def events(conversation, action)
      AuditEvent.where(conversation_id: conversation.id, action: action).order(:created_at, :id).to_a
    end

    def state(conversation, expected)
      expect("conversa em #{expected}", conversation.state == expected, conversation.state)
    end

    def count(conversation, action, expected)
      found = events(conversation, action).size
      expect("#{expected} #{action}", found == expected, found)
    end

    def escalated(conversation, reason)
      event = events(conversation, "conversation.escalated").last
      expect("conversation.escalated com reason #{reason}", event&.reason == reason, event ? event.reason.inspect : "ausente")
    end

    def wait_events(conversation)
      events(conversation, "message.created").select { |event| event.reason == DemoCheck.wait_reason && event.actor_type == "system" }
    end

    def timeout_sla(conversation)
      routed = events(conversation, "conversation.routed").last
      minutes = routed&.after&.fetch("sla_minutes", nil)
      hint = minutes == 1 ? "1 min" : "#{minutes.inspect} min; rode bin/rails panel:demo_sla BRAND=#{@brand.slug} MINUTES=1 antes do cenário"
      expect("SLA de 1 min na conversa", minutes == 1, hint)
    end

    def reply
      conversation = single_conversation or return
      state(conversation, "with_ai")
      replies = events(conversation, "agent.reply")
      expect("1 agent.reply", replies.size == 1, replies.size)
      delivered = replies.first && AuditEvent.exists?(action: "message.delivered", target_type: "Message",
                                                      target_id: replies.first.target_id)
      expect("message.delivered da resposta", delivered, delivered ? "presente" : "ausente")
    end

    def handoff
      conversation = single_conversation or return
      state(conversation, "awaiting_human")
      event = events(conversation, "conversation.escalated").last
      expect("conversation.escalated", event.present?, event ? event.reason.inspect : "ausente")
      if event
        origin = Routing::Queue.find_by(id: event.before&.fetch("queue_id", nil))
        destination = origin&.escalation_queue || origin
        current = Routing::Queue.find_by(id: conversation.queue_id)
        expect("na fila #{destination&.name.inspect}", destination.present? && conversation.queue_id == destination.id,
               current&.name.inspect)
      end
      record = Handoff.where(conversation_id: conversation.id).order(:created_at).last
      expect("Handoff com reason intencao_nao_identificada", record&.reason == "intencao_nao_identificada",
             record ? record.reason : "ausente")
      confidence = record&.context&.fetch("confidence", nil)
      expect("confiança 0,2", confidence == 0.2, confidence.inspect)
      line = Array(record&.context&.fetch("attempts", nil)).last
      expect("explicação da confiança em attempts", line.to_s.start_with?("Confiança 0,2: "), line.inspect)
    end

    def reopen
      conversation = single_conversation or return
      resolved = events(conversation, "conversation.resolved").first
      reopened = resolved && events(conversation, "conversation.reopened").find { |event| event.created_at >= resolved.created_at }
      expect("conversation.resolved e depois conversation.reopened", reopened.present?,
             [ resolved ? "resolved" : "sem resolved", reopened ? "reopened" : "sem reopened" ].join(", "))
      state(conversation, "with_ai")
      count(conversation, "agent.reply", 2)
    end

    def memory
      first = Conversation.find(@messages.first.conversation_id)
      second = Conversation.find(@messages.last.conversation_id)
      expect("duas conversas", @conversations.size == 2, @conversations.size)
      expect("conversas do mesmo lojista", first.contact_id == second.contact_id, [ first.contact_id, second.contact_id ].uniq.join(", "))
      expect("primeira conversa em closed", first.state == "closed", first.state)
      expect("segunda conversa em with_ai", second.state == "with_ai", second.state)
      memory = CustomerMemory.find_by(contact_id: second.contact_id)
      expect("customer_memory do lojista", memory.present?, memory ? memory.summary : "ausente")
      text = events(second, "agent.reply").last&.payload&.dig("payload", "action", "text")
      prefix = DemoCheck::MEMORY_PREFIX.fetch(@brand.locale)
      expect("agent.reply da segunda conversa com o prefixo da memória", text.to_s.start_with?(prefix), text.inspect)
    end

    def failure_duplicate
      conversation = single_conversation or return
      replies = events(conversation, "agent.reply")
      expect("1 agent.reply", replies.size == 1, replies.size)
      key = replies.first&.payload&.dig("payload", "idempotency_key")
      found = key ? ProcessedEvent.where(idempotency_key: key).count : 0
      expect("1 linha em processed_events para #{key.inspect}", found == 1, found)
    end

    def failure_stale
      conversation = @conversations.first
      count(conversation, "agent.action.stale", 1)
      escalated(conversation, DemoCheck.timeout_reason)
      state(conversation, "awaiting_human")
    end

    def failure_drop
      conversation = @conversations.first
      actions = AuditEvent.where(conversation_id: conversation.id, action: DemoCheck::ACTION_EVENTS).pluck(:action)
      expect("nenhum evento de ação do agente", actions.empty?, actions.empty? ? "nenhum" : actions.join(", "))
      waits = wait_events(conversation)
      expect("mensagem system com reason #{DemoCheck.wait_reason}", waits.any?, waits.size)
      escalated(conversation, DemoCheck.timeout_reason)
    end

    def failure_delay
      conversation = @conversations.first
      wait = wait_events(conversation).first
      reply = events(conversation, "agent.reply").first
      expect("mensagem system com reason #{DemoCheck.wait_reason}", wait.present?, wait ? "presente" : "ausente")
      expect("agent.reply", reply.present?, reply ? "presente" : "ausente")
      before = wait && reply && wait.created_at < reply.created_at
      expect("espera antes do agent.reply", before, before ? "sim" : "não")
      state(conversation, "with_ai")
      count(conversation, "conversation.escalated", 0)
    end
  end
end

namespace :demo do
  desc "Confere no Core um cenário de demonstração do simulador (SCENARIO, BRAND, CHANNEL, EXTERNAL_IDS)"
  task check: :environment do
    results = DemoCheck.run(scenario: ENV["SCENARIO"], brand: ENV["BRAND"], channel: ENV["CHANNEL"],
                            external_ids: ENV["EXTERNAL_IDS"])
    exit(1) unless DemoCheck.report(results)
  end
end

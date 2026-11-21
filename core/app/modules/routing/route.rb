module Routing
  # Ponto de entrada do roteamento. Roda dentro do Tenancy.with_brand de quem chama, na marca da
  # conversa, e grava cada decisão por Audit::Command:
  #   1. classificação (conversation.classified):
  #        intake:     categoria e urgência pelo Routing::Classifier, com a conversa em triage;
  #        categorize: categoria informada pelo agente; a conversa sai de with_ai para triage e
  #                    solta o atendente;
  #   2. regra: a primeira que casa com os fatos da conversa (Routing::Matcher). Sem regra, ou com
  #      a fila da regra inexistente, conversation.unrouted e a conversa fica em triage;
  #   3. fila: a da regra; quando o número de conversas abertas nela atinge a capacidade, segue a
  #      overflow_queue, até uma fila com vaga ou o fim da cadeia, que fica com a conversa;
  #   4. valores: prioridade da regra; SLA e atendente inicial da regra quando ela informa, senão da
  #      fila. No transbordo, SLA e atendente inicial da fila de transbordo;
  #   5. atribuição (conversation.routed, com a regra e a versão): ai leva ao atendente IA da marca
  #      e a with_ai; human leva a awaiting_human, sem atendente, com queued_at, e atualiza o painel
  #      do analista.
  #
  # A contagem das conversas abertas da fila é feita sem trava, e o número contado vai para o
  # audit_event.
  class Route
    TRIGGERS = %w[intake categorize].freeze

    class Error < StandardError; end

    # routed: true quando a conversa saiu de triage para uma fila.
    Result = Data.define(:conversation, :routed, :rule, :queue)

    def self.call(**options)
      new(**options).call
    end

    # conversation: Conversation em triage (intake) ou em with_ai (categorize).
    # trigger:      intake ou categorize.
    # text:         texto da mensagem; subject, o assunto do e-mail (intake).
    # category:     categoria informada pelo agente (categorize).
    # actor_id:     atendente que informou a categoria (categorize); padrão, o atendente da conversa.
    # received_at:  horário da mensagem; padrão, Current.received_at.
    def initialize(conversation:, trigger:, text: nil, subject: nil, category: nil, actor_id: nil, received_at: nil)
      raise ArgumentError, "trigger desconhecido: #{trigger.inspect}" unless TRIGGERS.include?(trigger.to_s)
      raise ArgumentError, "categoria não informada" if trigger.to_s == "categorize" && category.blank?

      @conversation = conversation
      @trigger = trigger.to_s
      @text = text
      @subject = subject
      @category = category
      @actor_id = actor_id
      @received_at = received_at || Current.received_at || Time.current
    end

    def call
      if Tenancy.current_brand_id != @conversation.brand_id.to_s
        raise ArgumentError, "Routing::Route roda dentro do Tenancy.with_brand da marca da conversa"
      end

      @brand = @conversation.brand
      @trigger == "intake" ? classify : recategorize

      rule = match_rule
      return unrouted("nenhuma regra casou") if rule.nil?

      chain = queue_chain(rule.fetch("then").fetch("queue"))
      return unrouted("a fila da regra não existe na marca", rule) if chain.empty?

      assign(rule, chain)
    end

    private

    def classify
      raise ArgumentError, "a conversa deve estar em triage" unless @conversation.state == "triage"

      result = Classifier.call(brand: @brand, text: @text, subject: @subject)
      command("conversation.classified", actor_type: "system") do |change|
        change.before = { category: @conversation.category, urgency: @conversation.urgency }
        @conversation.update!(category: result.category, urgency: result.urgency)
        change.after = { category: @conversation.category, urgency: @conversation.urgency }
        change.payload = {
          trigger: @trigger, category: result.category, urgency: result.urgency,
          matches: { category: result.category_matches, urgency: result.urgency_matches }, scores: result.scores,
          classifier_version: result.version
        }
      end
    end

    def recategorize
      raise ArgumentError, "a conversa deve estar em with_ai" unless @conversation.state == "with_ai"

      command("conversation.classified", actor_type: "ai", actor_id: @actor_id || @conversation.attendant_id) do |change|
        change.before = classification_snapshot
        @conversation.update!(state: "triage", attendant_id: nil, category: @category)
        change.after = classification_snapshot
        change.payload = { trigger: @trigger, category: @category, urgency: @conversation.urgency }
      end
    end

    def match_rule
      Matcher.new(CompiledRules.for(@brand), business_hours_for: method(:business_hours_for)).first_match(facts)
    end

    def facts
      contact = @conversation.contact
      {
        brand: @brand.slug, channel: @conversation.channel, category: @conversation.category,
        priority: @conversation.urgency, segment: contact.segment, language: contact.locale,
        received_at: @received_at
      }
    end

    def business_hours_for(queue_name)
      find_queue(queue_name)&.team&.business_hours
    end

    def find_queue(name)
      @queues ||= {}
      @queues.fetch(name) { @queues[name] = Routing::Queue.find_by(name: name) }
    end

    # Filas visitadas, da fila da regra até a que fica com a conversa, com as conversas abertas
    # contadas em cada uma. Vazia quando a fila da regra não existe.
    def queue_chain(name)
      queue = find_queue(name)
      chain = []
      while queue
        open_conversations = Conversation.where(queue_id: queue.id, state: Conversation::OPEN_STATES).count
        chain << { queue: queue, open_conversations: open_conversations }
        break if open_conversations < queue.capacity

        following = queue.overflow_queue
        break if following.nil? || chain.any? { |step| step[:queue].id == following.id }

        queue = following
      end
      chain
    end

    def assign(rule, chain)
      queue = chain.last[:queue]
      overflow = chain.size > 1
      result = rule.fetch("then")
      sla_minutes = overflow ? queue.sla_minutes : (result["sla_minutes"] || queue.sla_minutes)
      first_attendant = overflow ? queue.first_attendant : (result["first_attendant"] || queue.first_attendant)
      priority = result.fetch("priority")

      command("conversation.routed", actor_type: "system", routing_rule: RoutingRule.find(rule.fetch("id")),
                                     panel: first_attendant == "human") do |change|
        change.before = routing_snapshot
        @conversation.update!(
          queue_id: queue.id, priority: priority, sla_minutes: sla_minutes, **attendance(first_attendant)
        )
        change.after = routing_snapshot
        change.payload = {
          trigger: @trigger, rule: rule_summary(rule), queue: queue.name, priority: priority,
          sla_minutes: sla_minutes, first_attendant: first_attendant, attendant_id: @conversation.attendant_id,
          overflow: overflow,
          queue_chain: chain.map do |step|
            { queue: step[:queue].name, open_conversations: step[:open_conversations], capacity: step[:queue].capacity }
          end
        }
      end

      Result.new(conversation: @conversation, routed: true, rule: rule, queue: queue)
    end

    def attendance(first_attendant)
      if first_attendant == "ai"
        { state: "with_ai", attendant_id: ai_attendant.id, queued_at: nil }
      else
        { state: "awaiting_human", attendant_id: nil, queued_at: @received_at }
      end
    end

    def ai_attendant
      Attendant.first_ai || raise(Error, "a marca #{@brand.slug} não tem atendente IA")
    end

    def unrouted(reason, rule = nil)
      routing_rule = rule && RoutingRule.find(rule.fetch("id"))
      command("conversation.unrouted", actor_type: "system", reason: reason, routing_rule: routing_rule) do |change|
        change.before = change.after = { state: @conversation.state }
        change.payload = { trigger: @trigger, reason: reason, rule: rule && rule_summary(rule) }.compact
      end

      Result.new(conversation: @conversation, routed: false, rule: rule, queue: nil)
    end

    def command(type, **options)
      Audit::Command.call(brand: @brand, type: type, **options) do |change|
        yield change
        change.target = @conversation
        change.conversation = @conversation
        @conversation
      end
    end

    def rule_summary(rule)
      rule.slice("id", "rule_id", "version", "name", "position")
    end

    def classification_snapshot
      { state: @conversation.state, attendant_id: @conversation.attendant_id, category: @conversation.category }
    end

    def routing_snapshot
      {
        state: @conversation.state, queue_id: @conversation.queue_id, attendant_id: @conversation.attendant_id,
        priority: @conversation.priority, sla_minutes: @conversation.sla_minutes, queued_at: @conversation.queued_at&.utc&.iso8601(3)
      }
    end
  end
end

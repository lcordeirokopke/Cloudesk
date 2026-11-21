module Agents
  # Processa uma ação do agente (reply, escalate, categorize ou resolve) recebida pela API de ações.
  # A ação é o valor Kafka de agent.outbound, sem alteração, e a Idempotency-Key vem do Broker.
  #
  # Antes do banco:
  #   - corpo fora do schema action ou Idempotency-Key diferente da derivada do corpo
  #     (Contract::IdempotencyKey.for_action): invalid_payload;
  #   - marca do corpo inexistente: not_found.
  # Em um único Tenancy.with_brand, na marca do corpo:
  #   1. conversa com FOR UPDATE; inexistente na marca: not_found. A trava serializa as ações da
  #      mesma conversa, inclusive as duplicadas simultâneas, e as mensagens de entrada;
  #   2. chave em processed_events: devolve o resultado guardado, sem novo efeito nem audit_event;
  #   3. inbound_event_id que não é um message.created da conversa, ou based_on_sequence maior que
  #      last_sequence: invalid_payload;
  #   4. conversa fora de with_ai: rejected (agent.action.rejected);
  #   5. based_on_sequence menor que a sequência da última mensagem do lojista: stale
  #      (agent.action.stale);
  #   6. executa a ação dentro do Audit::Command do evento da ação (agent.<type>), que guarda o
  #      corpo completo da ação (ferramentas, model, carimbos de horário) e a Idempotency-Key; os
  #      eventos de domínio são gravados na mesma transação;
  #   7. grava o corpo da resposta em processed_events. accepted, stale e rejected são resultado
  #      final da chave; invalid_payload e not_found não são guardados.
  #
  # O ator dos eventos é a IA: actor_id é o atendente da conversa e, na recusa, o atendente IA da
  # marca.
  class ActionProcessor
    # status: código HTTP da resposta (:ok, :conflict, :unprocessable_content, :not_found).
    # body:   corpo da resposta no formato do schema action-response.
    Result = Data.define(:status, :body)

    STATUS_BY_RESULT = { "accepted" => :ok, "stale" => :conflict, "rejected" => :conflict }.freeze

    class KeyTaken < StandardError; end

    def self.call(**options)
      new(**options).call
    end

    # action:          corpo da ação já lido do JSON (Hash).
    # idempotency_key: header Idempotency-Key da chamada.
    def initialize(action:, idempotency_key:)
      @action = action
      @idempotency_key = idempotency_key
    end

    def call
      errors = Contract::Schemas.errors("action", @action)
      return invalid("a ação não segue o contrato: #{errors.join('; ')}") if errors.any?
      return invalid("a Idempotency-Key difere da derivada da ação") unless @idempotency_key == expected_key

      @brand = Brand.find_by(slug: @action.fetch("brand"))
      return not_found("marca #{@action.fetch('brand')} não encontrada") if @brand.nil?

      Current.traceparent ||= TraceContext.generate
      Tenancy.with_brand(@brand) { process }
    end

    private

    def type = @action.fetch("type")
    def based_on_sequence = @action.fetch("based_on_sequence")

    def expected_key
      Contract::IdempotencyKey.for_action(@action)
    end

    def process
      @conversation = Conversation.lock.find_by(id: @action.fetch("conversation_id"))
      return not_found("conversa #{@action.fetch('conversation_id')} não encontrada na marca") if @conversation.nil?

      stored = ProcessedEvent.find_by(idempotency_key: @idempotency_key)
      return replay(stored) if stored

      problem = consistency_problem
      return invalid(problem) if problem
      return reject unless @conversation.state == "with_ai"

      last_customer_sequence = Message.where(conversation_id: @conversation.id, author: "customer").maximum(:sequence)
      return stale(last_customer_sequence) if last_customer_sequence && based_on_sequence < last_customer_sequence

      accept
    end

    def consistency_problem
      inbound = AuditEvent.exists?(event_id: @action.fetch("inbound_event_id"), action: "message.created",
                                   conversation_id: @conversation.id)
      return "o inbound_event_id não é um message.created da conversa" unless inbound
      return "o based_on_sequence é maior que a última sequência da conversa" if based_on_sequence > @conversation.last_sequence

      nil
    end

    def replay(stored)
      Result.new(status: STATUS_BY_RESULT.fetch(stored.result.fetch("status")), body: stored.result)
    end

    def accept
      message_sequence = nil
      command = Audit::Command.call(brand: @brand, type: "agent.#{type}", actor_type: "ai",
                                    actor_id: @conversation.attendant_id) do |change|
        target = execute
        message_sequence = target.sequence if target.is_a?(Message)
        change.target = target
        change.conversation = @conversation
        change.sequence = message_sequence
        change.payload = { idempotency_key: @idempotency_key, action: @action }
      end

      finish(
        "status" => "accepted", "type" => type, "conversation_id" => @conversation.id,
        "event_id" => command.audit_event.event_id, "message_sequence" => message_sequence
      )
    end

    # Executa a ação e devolve o alvo do evento da ação: a mensagem gravada no reply, a conversa
    # nas demais.
    def execute
      case type
      when "reply" then reply
      when "escalate" then escalate
      when "categorize" then categorize
      when "resolve" then resolve
      end
    end

    # A resposta vai para a última mensagem do lojista até o based_on_sequence: a entrega lê dela o
    # canal, o número ou e-mail da marca e o destinatário.
    def reply
      replied = Message.where(conversation_id: @conversation.id, author: "customer")
                       .where(sequence: ..based_on_sequence).order(sequence: :desc).first!
      Conversations::Outbound.append!(
        conversation: @conversation, author: "ai", text: @action.fetch("text"),
        in_reply_to_sequence: replied.sequence, attendant: @conversation.attendant
      )
    end

    # with_ai -> awaiting_human na fila de escalação da fila atual, ou na própria fila atual
    # (Conversations::Escalate).
    def escalate
      Conversations::Escalate.call(
        conversation: @conversation, reason: @action.fetch("reason"), summary: @action.fetch("summary"),
        context: @action.fetch("context"), actor_type: "ai", actor_id: @conversation.attendant_id
      )
      @conversation
    end

    # Novo roteamento pela categoria do agente (Routing::Route); a conversa volta a with_ai, vai para
    # fila humana ou fica em triage. O webhook não é reenviado.
    def categorize
      Routing::Route.call(
        conversation: @conversation, trigger: "categorize", category: @action.fetch("category"),
        actor_id: @conversation.attendant_id
      )
      @conversation
    end

    # with_ai -> resolved, com resolved_at; o atendente segue na conversa. Nenhuma mensagem vai ao
    # lojista.
    def resolve
      transition("conversation.resolved", reason: @action["reason"]) do
        @conversation.update!(state: "resolved", resolved_at: received_at)
      end
    end

    def transition(event_type, reason:)
      Audit::Command.call(brand: @brand, type: event_type, actor_type: "ai", actor_id: @conversation.attendant_id,
                          reason: reason) do |change|
        change.before = conversation_snapshot
        yield change
        change.after = conversation_snapshot
        change.target = @conversation
        change.conversation = @conversation
      end
      @conversation
    end

    def reject
      command = refusal("agent.action.rejected", "conversa em #{@conversation.state}", actor_id: Attendant.first_ai&.id,
                                                                                      state: @conversation.state)
      finish(
        "status" => "rejected", "conversation_id" => @conversation.id,
        "event_id" => command.audit_event.event_id, "state" => @conversation.state
      )
    end

    def stale(last_customer_sequence)
      command = refusal("agent.action.stale", "mensagem do lojista mais nova que o based_on_sequence",
                        actor_id: @conversation.attendant_id, based_on_sequence: based_on_sequence,
                        last_customer_sequence: last_customer_sequence)
      finish(
        "status" => "stale", "conversation_id" => @conversation.id, "event_id" => command.audit_event.event_id,
        "based_on_sequence" => based_on_sequence, "last_customer_sequence" => last_customer_sequence
      )
    end

    def refusal(event_type, reason, actor_id:, **details)
      Audit::Command.call(brand: @brand, type: event_type, actor_type: "ai", actor_id: actor_id,
                          reason: reason) do |change|
        change.target = @conversation
        change.conversation = @conversation
        change.payload = { idempotency_key: @idempotency_key, action: @action, **details }
      end
    end

    # Guarda o resultado da chave. Com a conversa travada, a chave não pode ter sido gravada por
    # outra transação; se foi, a exceção desfaz a transação inteira e a ação não tem efeito.
    def finish(body)
      raise KeyTaken, "Idempotency-Key #{@idempotency_key} gravada por outra transação" unless
        ProcessedEvent.record(idempotency_key: @idempotency_key, result: body)

      Result.new(status: STATUS_BY_RESULT.fetch(body.fetch("status")), body: body)
    end

    def invalid(message)
      error(:unprocessable_content, "invalid_payload", message)
    end

    def not_found(message)
      error(:not_found, "not_found", message)
    end

    def error(status, code, message)
      Result.new(status: status, body: { "status" => "error", "error" => code, "message" => message })
    end

    def received_at
      Current.received_at || Time.current
    end

    def conversation_snapshot
      {
        state: @conversation.state, attendant_id: @conversation.attendant_id, queue_id: @conversation.queue_id,
        queued_at: @conversation.queued_at&.utc&.iso8601(3), resolved_at: @conversation.resolved_at&.utc&.iso8601(3)
      }
    end
  end
end

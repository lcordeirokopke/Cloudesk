module Audit
  # Serviço de comando: o caminho único pelo qual toda decisão do sistema é gravada.
  # Em uma única transação, na marca informada, ele executa a mudança de estado (o bloco), grava o
  # audit_event com o envelope completo e, quando o comando tem evento de saída, enfileira o job de
  # webhook. O Solid Queue grava o job pela mesma conexão do app: se a transação falha, não existe
  # mudança, audit_event nem job; se ela confirma, os três existem.
  #
  #   Audit::Command.call(brand: brand, type: "message.created", actor_type: "customer", webhook: true) do |change|
  #     message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
  #     change.target = message
  #     change.conversation = conversation
  #     change.sequence = message.sequence
  #     change.payload = { message: { author: "customer", channel: "whatsapp", text: "oi" } }
  #     message
  #   end
  class Command
    # O que o bloco informa sobre a mudança que executou. routing_rule, quando informada pelo bloco,
    # vale no lugar da informada na chamada: é o caso da versão de regra gravada pelo próprio bloco.
    Change = Struct.new(:target, :conversation, :sequence, :before, :after, :payload, :routing_rule)

    # value é o retorno do bloco.
    Result = Data.define(:value, :audit_event, :envelope)

    def self.call(**options, &block)
      new(**options).call(&block)
    end

    # brand:        Brand da transação.
    # type:         tipo do evento, gravado em audit_events.action e no envelope.
    # actor_type:   quem decidiu: customer, ai, analyst ou system.
    # actor_id:     id do ator, quando ele é um registro.
    # reason:       motivo da decisão.
    # routing_rule: versão da RoutingRule que casou; grava regra e versão no audit_event.
    # webhook:      true quando o evento sai para o Broker.
    def initialize(brand:, type:, actor_type:, actor_id: nil, reason: nil, routing_rule: nil, webhook: false)
      raise ArgumentError, "brand deve ser um Brand" unless brand.is_a?(Brand)

      @brand = brand
      @type = type
      @actor_type = actor_type
      @actor_id = actor_id
      @reason = reason
      @routing_rule = routing_rule
      @webhook = webhook
    end

    def call
      traceparent = Current.traceparent || TraceContext.generate
      received_at = Current.received_at || Time.current

      Tenancy.with_brand(@brand) do
        change = Change.new
        value = yield change
        raise ArgumentError, "o comando não informou o alvo da mudança" if change.target.nil?

        envelope = build_envelope(change, traceparent, received_at)
        audit_event = record(change, envelope)
        enqueue_webhook(envelope) if @webhook

        Result.new(value: value, audit_event: audit_event, envelope: envelope)
      end
    end

    private

    def build_envelope(change, traceparent, received_at)
      EventEnvelope.build(
        type: @type,
        brand: @brand.slug,
        conversation_id: change.conversation&.id,
        sequence: change.sequence,
        received_at: received_at,
        payload: change.payload || {},
        traceparent: traceparent
      )
    end

    def record(change, envelope)
      routing_rule = change.routing_rule || @routing_rule
      AuditEvent.create!(
        event_id: envelope.event_id,
        actor_type: @actor_type,
        actor_id: @actor_id,
        action: @type,
        target_type: change.target&.class&.name,
        target_id: change.target&.id,
        conversation: change.conversation,
        before: change.before,
        after: change.after,
        payload: envelope.to_h,
        reason: @reason,
        routing_rule: routing_rule,
        rule_version: routing_rule&.version,
        trace_id: envelope.trace_id
      )
    end

    # A marca e o traceparent seguem nos argumentos do job: as tabelas do Solid Queue ficam fora
    # do RLS, e o worker define a marca a partir deles.
    def enqueue_webhook(envelope)
      Agents::WebhookDeliveryJob.perform_later(
        brand_id: @brand.id,
        event_id: envelope.event_id,
        traceparent: envelope.traceparent.to_s
      )
    end
  end
end

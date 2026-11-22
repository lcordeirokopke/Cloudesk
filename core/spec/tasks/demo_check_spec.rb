require "rails_helper"
require "rake"

# Task demo:check: confere no Core os cenários de demonstração do simulador de canais. Cada cenário
# tem um caso montado com os serviços reais, que passa, e um caso com uma expectativa quebrada.
RSpec.describe "demo:check" do
  let(:brand) { infinitepay }
  let(:start) { Time.zone.parse("2026-11-21 14:00:00") }
  let(:fees) { "Qual a taxa do crédito parcelado em 12x?" }
  let(:greeting) { "Oi, tudo bem? Preciso de ajuda." }
  let(:fees_reply) { "As taxas da sua conta são: débito 1,37%, crédito à vista 3,15%, crédito em 12x 12,40% e Pix 0,00%." }

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("demo:check")
  end

  around { |example| travel_to(start) { example.run } }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  # Lojista novo no chat, como os lojistas dos cenários.
  def new_identity
    "app-demo-#{SecureRandom.hex(6)}"
  end

  # Mensagem do lojista; devolve o external_id.
  def customer(identity, text)
    external_id = SecureRandom.uuid
    Conversations::Intake.call(inbound_message(brand: brand, channel: "chat", identity: identity, text: text,
                                               external_id: external_id))
    external_id
  end

  def conversation_of(external_id)
    in_brand { Conversation.find(Message.find_by!(channel: "chat", external_id: external_id).conversation_id) }
  end

  def process(conversation, **attributes)
    action = agent_action(conversation, **attributes)
    Agents::ActionProcessor.call(action: action, idempotency_key: Contract::IdempotencyKey.for_action(action))
  end

  def agent_reply(external_id, text = fees_reply, **attributes)
    process(conversation_of(external_id), example: "reply", text: text, **attributes)
  end

  def agent_resolve(external_id)
    process(conversation_of(external_id), example: "resolve")
  end

  def agent_escalate(external_id, confidence:, explanation:)
    example = JSON.parse(Contract::Schemas.root.join("examples", "action", "valid", "escalate.json").read)
    context = example.fetch("context").merge("intent" => "desconhecida", "entities" => {}, "tools" => [],
                                             "confidence" => confidence,
                                             "attempts" => [ "Classificação da mensagem por palavras-chave sem ferramenta aplicável", explanation ])
    process(conversation_of(external_id), example: "escalate", tools: [], reason: "intencao_nao_identificada",
                                          summary: "Mensagem do lojista sem intenção identificada.", context: context)
  end

  def deliver_last_reply(external_id)
    conversation = conversation_of(external_id)
    message = in_brand { Message.where(conversation_id: conversation.id, author: "ai").order(:sequence).last }
    job = jobs_of(Channels::DeliveryJob).find { |item| job_arguments(item)["message_id"] == message.id }
    Channels::DeliveryJob.perform_now(**job_arguments(job).slice("brand_id", "message_id", "traceparent").symbolize_keys)
  end

  def refresh_memory(external_id)
    conversation = conversation_of(external_id)
    job = jobs_of(Conversations::MemoryRefreshJob).find { |item| job_arguments(item)["conversation_id"] == conversation.id }
    Conversations::MemoryRefreshJob.perform_now(**job_arguments(job).slice("brand_id", "contact_id", "conversation_id").symbolize_keys)
  end

  def sweep_at(seconds)
    travel_to(start + seconds.seconds)
    Conversations::AiTimeoutSweepJob.perform_now
  end

  def check(scenario, external_ids)
    DemoCheck.run(scenario: scenario, brand: brand.slug, channel: "chat", external_ids: external_ids.join(","))
  end

  def failed(results)
    results.reject(&:ok).map(&:label)
  end

  def expect_pass(results)
    expect(results.reject(&:ok).map { |result| "#{result.label}: #{result.found}" }).to eq([])
  end

  describe "reply" do
    def scenario(deliver: true)
      id = customer(new_identity, fees)
      agent_reply(id)
      deliver_last_reply(id) if deliver
      [ id ]
    end

    it "passa com a conversa com a IA, a resposta e a entrega" do
      expect_pass(check("reply", scenario))
    end

    it "falha sem a entrega da resposta" do
      expect(failed(check("reply", scenario(deliver: false)))).to eq([ "message.delivered da resposta" ])
    end
  end

  describe "handoff" do
    def scenario(confidence: 0.2, explanation: "Confiança 0,2: base 0,2 por intencao_nao_identificada")
      id = customer(new_identity, "Quero mudar o endereço cadastrado.")
      agent_escalate(id, confidence: confidence, explanation: explanation)
      [ id ]
    end

    it "passa com a conversa aguardando o analista na fila de escalação e a confiança explicada" do
      results = check("handoff", scenario)

      expect_pass(results)
      expect(results.map(&:label)).to include("na fila \"ip-suporte-geral\"")
    end

    it "falha com outra confiança" do
      results = check("handoff", scenario(confidence: 0.35, explanation: "Confiança 0,35: base 0,5 por repasse_nao_localizado"))

      expect(failed(results)).to eq([ "confiança 0,2", "explicação da confiança em attempts" ])
    end
  end

  describe "reopen" do
    def scenario(second_reply: true)
      identity = new_identity
      first = customer(identity, fees)
      agent_reply(first)
      thanks = customer(identity, "Obrigado, era só isso!")
      agent_resolve(thanks)
      again = customer(identity, fees)
      agent_reply(again) if second_reply
      [ first, thanks, again ]
    end

    it "passa com a conversa resolvida, reaberta e respondida duas vezes" do
      expect_pass(check("reopen", scenario))
    end

    it "falha sem a segunda resposta" do
      expect(failed(check("reopen", scenario(second_reply: false)))).to eq([ "2 agent.reply" ])
    end
  end

  describe "memory" do
    def scenario(close: true)
      identity = new_identity
      first = customer(identity, fees)
      agent_reply(first)
      thanks = customer(identity, "Obrigado, era só isso!")
      agent_resolve(thanks)
      refresh_memory(thanks)
      MemoryDemoClose.close(conversation_of(thanks).id) if close
      second = customer(identity, fees)
      agent_reply(second, "Vi que você já falou com a gente sobre taxas em 21/11/2026. #{fees_reply}")
      [ first, thanks, second ]
    end

    it "passa com a primeira conversa encerrada, a memória e a resposta com o prefixo" do
      results = check("memory", scenario)

      expect_pass(results)
      expect(results.find { |result| result.label == "customer_memory do lojista" }.found).to include("taxas")
    end

    it "falha sem o encerramento da primeira conversa" do
      results = check("memory", scenario(close: false))

      expect(failed(results)).to include("duas conversas", "primeira conversa em closed")
    end
  end

  describe "failure-duplicate" do
    def scenario(replies:)
      id = customer(new_identity, "#{greeting} [falha:duplicate]")
      replies.times { agent_reply(id, "Olá! Sou o assistente virtual.") }
      [ id ]
    end

    it "passa com a ação repetida gravada uma vez" do
      expect_pass(check("failure-duplicate", scenario(replies: 2)))
    end

    it "falha sem resposta" do
      expect(failed(check("failure-duplicate", scenario(replies: 0)))).to include("1 agent.reply")
    end
  end

  describe "cenários de timeout" do
    before { PanelDemoSla.apply(brand.slug, 1) }

    describe "failure-stale" do
      def scenario
        identity = new_identity
        first = customer(identity, greeting)
        agent_reply(first, "Olá! Sou o assistente virtual.")
        second = customer(identity, "#{greeting} [falha:stale]")
        agent_reply(second, "Olá! Sou o assistente virtual.", based_on_sequence: 2)
        sweep_at(31)
        sweep_at(61)
        [ first, second ]
      end

      it "passa com a ação recusada por contexto desatualizado e a escalação pelo timeout" do
        expect_pass(check("failure-stale", scenario))
      end

      it "falha sem o SLA de 1 min e lembra o panel:demo_sla" do
        PanelDemoSla.reset(brand.slug)
        id = customer(new_identity, "#{greeting} [falha:stale]")

        results = check("failure-stale", [ id ])

        sla = results.find { |result| result.label == "SLA de 1 min na conversa" }
        expect(sla.ok).to be(false)
        expect(sla.found).to include("120 min", "panel:demo_sla BRAND=infinitepay MINUTES=1")
      end
    end

    describe "failure-drop" do
      def scenario(agent_answers: false)
        id = customer(new_identity, "#{greeting} [falha:drop]")
        agent_reply(id, "Olá! Sou o assistente virtual.") if agent_answers
        sweep_at(31)
        sweep_at(61)
        [ id ]
      end

      it "passa com a espera e a escalação sem ação do agente" do
        expect_pass(check("failure-drop", scenario))
      end

      it "falha quando o agente respondeu" do
        expect(failed(check("failure-drop", scenario(agent_answers: true)))).to include(
          "nenhum evento de ação do agente", "mensagem system com reason ai_timeout_wait"
        )
      end
    end

    describe "failure-delay" do
      def scenario(reply_at:)
        id = customer(new_identity, "#{greeting} [falha:delay=50000]")
        if reply_at < 31
          travel_to(start + reply_at.seconds)
          agent_reply(id, "Olá! Sou o assistente virtual.")
          sweep_at(31)
        else
          sweep_at(31)
          travel_to(start + reply_at.seconds)
          agent_reply(id, "Olá! Sou o assistente virtual.")
        end
        sweep_at(61)
        [ id ]
      end

      it "passa com a espera antes da resposta e sem escalação" do
        expect_pass(check("failure-delay", scenario(reply_at: 51)))
      end

      it "falha quando a resposta chega antes da espera" do
        expect(failed(check("failure-delay", scenario(reply_at: 5)))).to include(
          "mensagem system com reason ai_timeout_wait", "espera antes do agent.reply"
        )
      end
    end
  end

  it "falha com a mensagem não encontrada pelo external_id" do
    results = check("reply", [ "nao-existe" ])

    expect(results.map { |result| [ result.label, result.ok, result.found ] }).to eq([ [ "mensagem nao-existe", false, "não encontrada" ] ])
  end

  it "recusa cenário, canal e marca desconhecidos e a falta de EXTERNAL_IDS" do
    expect { DemoCheck.run(scenario: "outro", brand: "infinitepay", channel: "chat", external_ids: "a") }
      .to raise_error(ArgumentError, /cenário desconhecido/)
    expect { DemoCheck.run(scenario: "reply", brand: "infinitepay", channel: "sms", external_ids: "a") }
      .to raise_error(ArgumentError, /canal desconhecido/)
    expect { DemoCheck.run(scenario: "reply", brand: "outra", channel: "chat", external_ids: "a") }
      .to raise_error(ArgumentError, /não encontrada/)
    expect { DemoCheck.run(scenario: "reply", brand: "infinitepay", channel: "chat", external_ids: "") }
      .to raise_error(ArgumentError, /EXTERNAL_IDS/)
  end

  it "não grava nada" do
    id = customer(new_identity, fees)
    agent_reply(id)
    counts = -> { in_brand { [ AuditEvent.count, Message.count, ProcessedEvent.count, Conversation.count ] } }
    before = counts.call

    check("reply", [ id ])
    check("memory", [ id ])

    expect(counts.call).to eq(before)
  end

  describe "task" do
    around do |example|
      previous = ENV.to_h.slice("SCENARIO", "BRAND", "CHANNEL", "EXTERNAL_IDS")
      example.run
    ensure
      %w[SCENARIO BRAND CHANNEL EXTERNAL_IDS].each { |name| ENV[name] = previous[name] }
    end

    def run_task(scenario, external_ids)
      ENV.update("SCENARIO" => scenario, "BRAND" => brand.slug, "CHANNEL" => "chat", "EXTERNAL_IDS" => external_ids.join(","))
      task = Rake::Task["demo:check"]
      task.reenable
      task.invoke
    end

    it "imprime uma linha ok por expectativa e termina sem erro" do
      id = customer(new_identity, fees)
      agent_reply(id)
      deliver_last_reply(id)

      expect { run_task("reply", [ id ]) }.to output(/^ok      conversa em with_ai: with_ai$/).to_stdout
    end

    it "imprime a linha falhou e termina com código 1" do
      expect { run_task("reply", [ "nao-existe" ]) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(/^falhou  mensagem nao-existe: não encontrada$/).to_stdout
    end
  end
end

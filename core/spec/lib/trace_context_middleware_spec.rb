require "rails_helper"

RSpec.describe TraceContextMiddleware do
  let(:header) { "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }
  let(:seen) { {} }
  let(:app) do
    lambda do |_env|
      seen[:traceparent] = Current.traceparent
      seen[:received_at] = Current.received_at
      [ 200, {}, [] ]
    end
  end

  after { Current.reset }

  it "continua o trace do header traceparent durante a requisição" do
    described_class.new(app).call("HTTP_TRACEPARENT" => header)

    expect(seen[:traceparent].trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    expect(seen[:traceparent].parent_id).not_to eq("00f067aa0ba902b7")
  end

  it "inicia um trace quando a requisição chega sem header" do
    described_class.new(app).call({})

    expect(TraceContext.parse(seen[:traceparent].to_s)).to eq(seen[:traceparent])
  end

  it "carimba o horário de recebimento" do
    before_call = Time.current
    described_class.new(app).call({})

    expect(seen[:received_at]).to be_between(before_call, Time.current)
  end

  it "fica na pilha do app, depois do executor que limpa Current e do recarregamento de código" do
    middlewares = Rails.application.middleware.map(&:klass)

    expect(middlewares).to include(described_class)
    expect(middlewares.index(described_class)).to be > middlewares.index(ActionDispatch::Executor)
    expect(middlewares.index(described_class)).to be > middlewares.index(ActionDispatch::Callbacks)
    if middlewares.include?(ActionDispatch::Reloader)
      expect(middlewares.index(described_class)).to be > middlewares.index(ActionDispatch::Reloader)
    end
  end

  it "não deixa o contexto de uma requisição para a seguinte" do
    get_trace = -> { Rack::MockRequest.new(Rails.application).get("/up", "HTTP_TRACEPARENT" => header) }

    expect(get_trace.call.status).to eq(200)
    expect(Current.traceparent).to be_nil
    expect(Current.received_at).to be_nil
  end
end

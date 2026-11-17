# Middleware Rack que abre o contexto de cada requisição HTTP: carimba o horário de recebimento
# (received_at) e continua o trace do header traceparent, ou inicia um trace quando o header falta
# ou é inválido. Os dois valores ficam em Current até o fim da requisição.
# Fica depois de ActionDispatch::Executor na pilha; o Rails limpa Current antes e depois de cada requisição.
# Este arquivo é carregado por require em config/application.rb e fica fora do autoload.
class TraceContextMiddleware
  HEADER = "HTTP_TRACEPARENT".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    Current.received_at = Time.current
    Current.traceparent = TraceContext.continue(env[HEADER])
    @app.call(env)
  end
end

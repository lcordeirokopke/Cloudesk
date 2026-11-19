# Middleware Rack que abre o contexto de cada requisição HTTP: carimba o horário de recebimento
# (received_at) e continua o trace do header traceparent, ou inicia um trace quando o header falta
# ou é inválido. Os dois valores ficam em Current até o fim da requisição.
# Fica depois de ActionDispatch::Executor, que limpa Current antes e depois de cada requisição, e depois de
# ActionDispatch::Callbacks, que vem depois do ActionDispatch::Reloader em desenvolvimento: o recarregamento
# de código troca a classe Current, e o valor gravado antes dele se perderia.
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

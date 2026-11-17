# Dados da requisição ou do job corrente. O Rails limpa os atributos antes e depois de cada requisição.
#   traceparent: TraceContext::Traceparent do salto corrente.
#   received_at: horário em que o Core recebeu a requisição HTTP.
class Current < ActiveSupport::CurrentAttributes
  attribute :traceparent, :received_at
end

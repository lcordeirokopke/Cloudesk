module Agents
  # Falha no envio de um webhook ao Broker.
  #   Transient: o Broker pode aceitar depois (408, 429, 5xx, erro de rede, inclusive de DNS); o job
  #              tenta de novo com backoff.
  #   Permanent: o Broker recusou o webhook (os demais status) ou o evento não pode virar webhook; o
  #              job falha sem nova tentativa e fica na fila de falhas do Solid Queue.
  class WebhookError < StandardError
    class Transient < WebhookError; end
    class Permanent < WebhookError; end
  end
end

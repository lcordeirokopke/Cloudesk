module Channels
  # Falha na entrega de uma mensagem ao canal.
  #   Transient: o canal pode aceitar depois (5xx, erro de rede); o job tenta de novo com backoff.
  #   Permanent: o canal recusou a mensagem (4xx); o job falha sem nova tentativa e fica na fila de
  #              falhas do Solid Queue.
  class DeliveryError < StandardError
    class Transient < DeliveryError; end
    class Permanent < DeliveryError; end
  end
end

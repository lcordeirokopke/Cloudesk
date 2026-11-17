# Contexto de trace no formato traceparent do W3C Trace Context:
#   versão-trace_id-parent_id-flags, por exemplo 00-<32 hex>-<16 hex>-01.
# O trace_id identifica o caminho inteiro de uma mensagem; o parent_id identifica o salto que
# produziu o header. Cada salto mantém o trace_id e gera um parent_id próprio.
module TraceContext
  VERSION = "00".freeze
  SAMPLED = "01".freeze
  PATTERN = /\A00-(?<trace_id>[0-9a-f]{32})-(?<parent_id>[0-9a-f]{16})-(?<flags>[0-9a-f]{2})\z/
  INVALID_TRACE_ID = ("0" * 32).freeze
  INVALID_PARENT_ID = ("0" * 16).freeze

  Traceparent = Data.define(:trace_id, :parent_id, :flags) do
    # Mesmo trace, com o parent_id do salto corrente.
    def child
      with(parent_id: SecureRandom.hex(8))
    end

    def to_s
      "#{VERSION}-#{trace_id}-#{parent_id}-#{flags}"
    end
  end

  class << self
    # Devolve o Traceparent do header, ou nil quando o header falta ou é inválido.
    # Só a versão 00 é aceita; trace_id e parent_id zerados são inválidos.
    def parse(header)
      match = PATTERN.match(header.to_s.strip)
      return nil unless match
      return nil if match[:trace_id] == INVALID_TRACE_ID || match[:parent_id] == INVALID_PARENT_ID

      Traceparent.new(trace_id: match[:trace_id], parent_id: match[:parent_id], flags: match[:flags])
    end

    # Inicia um trace.
    def generate
      Traceparent.new(trace_id: SecureRandom.hex(16), parent_id: SecureRandom.hex(8), flags: SAMPLED)
    end

    # Continua o trace do header com um parent_id próprio; sem header válido, inicia um trace.
    def continue(header)
      parse(header)&.child || generate
    end
  end
end

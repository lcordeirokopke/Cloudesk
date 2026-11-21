module Admin
  # Edição recusada por validação; messages tem uma mensagem por problema encontrado.
  class Invalid < Error
    attr_reader :messages

    def initialize(messages)
      @messages = Array(messages)
      super(@messages.join("; "))
    end
  end
end

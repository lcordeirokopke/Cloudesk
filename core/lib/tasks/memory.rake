# Encerramento de demonstração da memória do lojista: leva uma conversa resolved a closed sem
# esperar o prazo de reabertura da marca, para que a próxima mensagem do lojista abra outra
# conversa. A transição passa pelo Audit::Command (conversation.closed, ator operator) com o papel da
# aplicação; o prazo de reabertura da marca não muda.
#   bin/rails memory:demo_close CONVERSATION=<id>
module MemoryDemoClose
  REASON = "demonstração".freeze

  module_function

  # Devolve a conversa em closed.
  def close(conversation_id)
    raise ArgumentError, "informe CONVERSATION=<id>" if conversation_id.to_s.empty?

    brand = brand_of(conversation_id)
    Tenancy.with_brand(brand) do
      conversation = Conversation.lock.find(conversation_id)
      unless conversation.state == "resolved"
        raise ArgumentError, "a conversa #{conversation_id} está em #{conversation.state}; só resolved vai a closed"
      end

      Audit::Command.call(brand: brand, type: "conversation.closed", actor_type: "operator", reason: REASON) do |change|
        change.before = { state: conversation.state }
        conversation.transition_to!("closed")
        change.after = { state: conversation.state }
        change.target = conversation
        change.conversation = conversation
        conversation
      end.value
    end
  end

  # Marca da conversa, procurando a conversa em cada marca.
  def brand_of(conversation_id)
    Brand.order(:slug).each do |brand|
      return brand if Tenancy.with_brand(brand) { Conversation.exists?(id: conversation_id) }
    end
    raise ArgumentError, "conversa #{conversation_id} não encontrada"
  end
end

namespace :memory do
  desc "Leva uma conversa resolved a closed para demonstração da memória (CONVERSATION=<id>)"
  task demo_close: :environment do
    conversation = MemoryDemoClose.close(ENV["CONVERSATION"])
    puts "Conversa #{conversation.id} em #{conversation.state}"
  end
end

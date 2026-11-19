module Channels
  module Email
    # Varredura recorrente do Mailpit: busca as mensagens sem tag e enfileira o IngestJob de cada uma.
    # Toda mensagem tratada pelo IngestJob recebe uma tag; por isso a busca devolve só o que o webhook
    # do Mailpit perdeu. Uma mensagem com IngestJob já na fila é tratada duas vezes sem efeito
    # repetido: o InboundEmail é único por (message_id, message_checksum). Uma mensagem que recebe
    # tag durante a paginação desloca as páginas seguintes; o que ficar de fora entra na próxima
    # varredura.
    class SweepJob < ApplicationJob
      queue_as :default

      QUERY = "!is:tagged".freeze
      PAGE_SIZE = 50

      def perform
        client = Mailpit::Client.new
        start = 0

        loop do
          page = client.search(QUERY, start: start, limit: PAGE_SIZE)
          messages = Array(page["messages"])
          messages.each { |message| IngestJob.perform_later(message.fetch("ID")) }

          start += messages.size
          break if messages.size < PAGE_SIZE
        end
      end
    end
  end
end

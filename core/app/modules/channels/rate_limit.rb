module Channels
  # Limite de taxa de entrada por marca, nos canais WhatsApp e chat. Janela fixa de 1 segundo: cada
  # marca tem um contador por segundo no Solid Cache, com a chave inbound_rate:<brand_id>:<segundo>,
  # incrementado pelo número de mensagens da requisição. A requisição é recusada quando o total de
  # alguma marca na janela passa de brands.inbound_rate_limit_per_second.
  #
  # Roda antes do Conversations::Intake, fora de transação de domínio. As marcas são contadas uma de
  # cada vez, e o incremento de uma marca já contada fica mesmo quando outra marca da mesma requisição
  # é recusada: o contador mede tentativas na janela. A recusa não grava nada no domínio e vai só para
  # o log.
  #
  # Contador indisponível (increment devolve nil: null store ou erro do cache): a marca passa, com
  # log. As chaves não expiram; as antigas saem pelo max_size do Solid Cache.
  #
  #   result = Channels::RateLimit.check({ brand => 3 }, channel: "whatsapp")
  #   result.allowed  # false quando alguma marca passou do limite; brand, count e limit são dela
  module RateLimit
    # count: total da marca na janela depois do incremento (nil com o contador indisponível).
    Result = Data.define(:allowed, :brand, :count, :limit)

    ALLOWED = Result.new(allowed: true, brand: nil, count: nil, limit: nil)

    module_function

    # counts: { Brand => número de mensagens da requisição }.
    def check(counts, channel:, now: Time.current)
      second = now.to_i

      counts.each do |brand, count|
        total = Rails.cache.increment(key(brand, second), count)
        limit = brand.inbound_rate_limit_per_second

        if total.nil?
          Rails.logger.warn("limite de taxa sem contador: marca #{brand.slug}, canal #{channel}; mensagem aceita")
          next
        end
        next if total <= limit

        Rails.logger.warn("limite de taxa: marca #{brand.slug}, canal #{channel}, #{total} mensagens no segundo, limite #{limit}")
        return Result.new(allowed: false, brand: brand, count: total, limit: limit)
      end

      ALLOWED
    end

    def key(brand, second)
      "inbound_rate:#{brand.id}:#{second}"
    end
  end
end

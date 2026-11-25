module Channels
  # Limite de taxa de entrada por marca, no WhatsApp e na entrada JSON do chat (check), e limite
  # próprio do widget de chat (check_widget).
  #
  # check: janela fixa de 1 segundo. Cada marca tem um contador por segundo no Solid Cache, com a chave
  # inbound_rate:<brand_id>:<segundo>, incrementado pelo número de mensagens da requisição. A
  # requisição é recusada quando o total de alguma marca na janela passa de
  # brands.inbound_rate_limit_per_second.
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
  #
  # check_widget: limite por lojista (contact.id), em janela fixa de WIDGET_CONTACT_WINDOW segundos, e
  # teto do widget por marca, em janela fixa de 1 segundo, em chaves widget_rate separadas do contador
  # da marca: o widget não lê nem incrementa inbound_rate. O lojista é conferido primeiro, e a recusa
  # dele não chega ao contador do widget da marca. As demais regras são as de check: fora de transação
  # de domínio, contagem de tentativas, recusa só no log e contador indisponível deixando passar.
  #
  #   result = Channels::RateLimit.check_widget(brand, contact)
  #   result.allowed  # false na recusa; scope, count, limit e retry_after são dela
  module RateLimit
    # count: total da marca na janela depois do incremento (nil com o contador indisponível).
    Result = Data.define(:allowed, :brand, :count, :limit)

    ALLOWED = Result.new(allowed: true, brand: nil, count: nil, limit: nil)

    # Widget de chat: mensagens por lojista em cada janela de WIDGET_CONTACT_WINDOW segundos, e
    # mensagens por segundo do widget em cada marca.
    WIDGET_CONTACT_LIMIT = 5
    WIDGET_CONTACT_WINDOW = 10
    WIDGET_BRAND_LIMIT = 10

    # scope: :contact ou :brand na recusa. retry_after: segundos até a janela seguinte.
    WidgetResult = Data.define(:allowed, :scope, :count, :limit, :retry_after)

    WIDGET_ALLOWED = WidgetResult.new(allowed: true, scope: nil, count: nil, limit: nil, retry_after: nil)

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

    def check_widget(brand, contact, now: Time.current)
      second = now.to_i
      subject = "marca #{brand.slug}, lojista #{contact.id}, widget de chat"

      total = Rails.cache.increment(widget_contact_key(brand, contact, second), 1)
      if total.nil?
        Rails.logger.warn("limite de taxa sem contador: #{subject}; limite do lojista não conferido")
      elsif total > WIDGET_CONTACT_LIMIT
        Rails.logger.warn("limite de taxa: #{subject}, #{total} mensagens em #{WIDGET_CONTACT_WINDOW} s, limite #{WIDGET_CONTACT_LIMIT}")
        return WidgetResult.new(allowed: false, scope: :contact, count: total, limit: WIDGET_CONTACT_LIMIT,
                                retry_after: WIDGET_CONTACT_WINDOW - (second % WIDGET_CONTACT_WINDOW))
      end

      total = Rails.cache.increment(widget_brand_key(brand, second), 1)
      if total.nil?
        Rails.logger.warn("limite de taxa sem contador: #{subject}; teto do widget não conferido")
      elsif total > WIDGET_BRAND_LIMIT
        Rails.logger.warn("limite de taxa: #{subject}, #{total} mensagens no segundo na marca, limite #{WIDGET_BRAND_LIMIT}")
        return WidgetResult.new(allowed: false, scope: :brand, count: total, limit: WIDGET_BRAND_LIMIT, retry_after: 1)
      end

      WIDGET_ALLOWED
    end

    def key(brand, second)
      "inbound_rate:#{brand.id}:#{second}"
    end

    def widget_contact_key(brand, contact, second)
      "widget_rate:#{brand.id}:contact:#{contact.id}:#{second / WIDGET_CONTACT_WINDOW}"
    end

    def widget_brand_key(brand, second)
      "widget_rate:#{brand.id}:#{second}"
    end
  end
end

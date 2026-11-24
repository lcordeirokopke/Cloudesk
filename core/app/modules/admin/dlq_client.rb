require "net/http"

module Admin
  # Cliente dos endpoints da DLQ no broker-web (Broker::DlqEndpoints), usado pela tela /admin/dlq.
  # O Kafka fica só no Broker: o Core lista e republica as mensagens de agent.dlq por HTTP, em
  # BROKER_DLQ_URL, com chamadas assinadas por Contract::Signature e BROKER_DLQ_SECRET sobre o
  # caminho com a query string e o corpo, e com o traceparent da requisição. Cada chamada abre uma
  # conexão nova, fora de transação.
  #
  #   list(brand:, limit:)                  mensagens da marca, como o Broker devolve (hashes)
  #   reprocess(brand:, partition:, offset:) origem, destino e diagnóstico da republicação
  #
  # Erro de rede ou status diferente de 200 levanta Admin::DlqClient::Error, com a mensagem para a
  # tela.
  module DlqClient
    OPEN_TIMEOUT = 2
    READ_TIMEOUT = 10

    class Error < StandardError; end

    # SocketError cobre a falha de resolução de nome (Socket::ResolutionError).
    NETWORK_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE, SocketError, EOFError
    ].freeze

    module_function

    def list(brand:, limit: 50)
      uri = URI.join(base_url, "/dlq/messages")
      uri.query = URI.encode_www_form(brand: brand.slug, limit: limit)
      call(Net::HTTP::Get.new(uri), uri, "").fetch("messages")
    end

    def reprocess(brand:, partition:, offset:)
      uri = URI.join(base_url, "/dlq/messages/#{Integer(partition)}/#{Integer(offset)}/reprocess")
      call(Net::HTTP::Post.new(uri), uri, JSON.generate(brand: brand.slug))
    end

    def call(request, uri, body, now: Time.now)
      request["Content-Type"] = "application/json"
      request["traceparent"] = (Current.traceparent || TraceContext.generate).to_s
      Contract::Signature.headers(
        secret: ENV.fetch("BROKER_DLQ_SECRET"), method: request.method, path: uri.request_uri, body: body, now: now
      ).each { |name, value| request[name] = value }
      request.body = body unless body.empty?

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end
      parse!(response)
    rescue *NETWORK_ERRORS => error
      raise Error, "Broker indisponível: #{error.class}: #{error.message}"
    end

    # O Net::HTTP entrega o corpo em ASCII-8BIT; o Broker responde JSON em UTF-8.
    def parse!(response)
      status = response.code.to_i
      text = response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      data = begin
        JSON.parse(text)
      rescue JSON::ParserError
        nil
      end
      return data if status == 200 && data.is_a?(Hash)

      detail = data.is_a?(Hash) ? [ data["error"], data["message"] ].compact.join(": ") : text.truncate(300)
      raise Error, "Broker respondeu #{status}: #{detail}"
    end

    def base_url
      ENV.fetch("BROKER_DLQ_URL")
    end
  end
end

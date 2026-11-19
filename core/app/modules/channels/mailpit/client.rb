require "net/http"

module Channels
  module Mailpit
    # Cliente da API HTTP do Mailpit (MAILPIT_API_URL).
    #   raw(id):                       GET /api/v1/message/{ID}/raw, o e-mail original em texto puro;
    #   tag(ids, tags):                PUT /api/v1/tags; sobrescreve as tags das mensagens;
    #   search(query, start:, limit:): GET /api/v1/search; resposta com messages, messages_count e total.
    # Erro de rede e status fora de 2xx lançam Client::Error.
    class Client
      class Error < StandardError; end

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      NETWORK_ERRORS = [
        Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
        SocketError, EOFError
      ].freeze

      def initialize(base_url: Settings.mailpit_api_url)
        @base_url = base_url.chomp("/")
      end

      def raw(id)
        request(Net::HTTP::Get.new(uri("/api/v1/message/#{URI.encode_uri_component(id.to_s)}/raw"))).body
      end

      def tag(ids, tags)
        put = Net::HTTP::Put.new(uri("/api/v1/tags"))
        put["Content-Type"] = "application/json"
        put.body = { "IDs" => Array(ids), "Tags" => Array(tags) }.to_json
        request(put)
        true
      end

      def search(query, start: 0, limit: 50)
        get = Net::HTTP::Get.new(uri("/api/v1/search", query: query, start: start, limit: limit))
        JSON.parse(request(get).body)
      end

      private

      def uri(path, **query)
        uri = URI("#{@base_url}#{path}")
        uri.query = URI.encode_www_form(query) if query.any?
        uri
      end

      def request(http_request)
        uri = http_request.uri
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(http_request)
        end
        raise Error, "Mailpit respondeu #{response.code} em #{http_request.method} #{uri.path}" unless response.code.to_i.between?(200, 299)

        response
      rescue *NETWORK_ERRORS => error
        raise Error, "Mailpit indisponível: #{error.class}: #{error.message}"
      end
    end
  end
end

require "json_schemer"

module Contract
  # Schemas do contrato entre Core, Broker e agente. Os arquivos ficam em contracts/, na raiz do
  # repositório, e a pasta chega ao contêiner pela variável CONTRACTS_PATH. Os testes de contrato em
  # Python leem os mesmos arquivos.
  # Este código não acessa o banco: o Broker o usa.
  module Schemas
    VERSION = "v1".freeze

    class InvalidPayload < StandardError
      attr_reader :schema, :errors

      def initialize(schema, errors)
        @schema = schema
        @errors = errors
        super("payload fora do contrato #{schema}: #{errors.join('; ')}")
      end
    end

    class << self
      # Pasta da versão corrente do contrato.
      def root
        Pathname.new(ENV.fetch("CONTRACTS_PATH")).join(VERSION)
      end

      # Nomes dos schemas, sem a extensão: "action", "webhook.message-created" etc.
      def names
        root.join("schemas").glob("*.json").map { |path| path.basename(".json").to_s }.sort
      end

      def valid?(name, data)
        schemer(name).valid?(data.as_json)
      end

      # Mensagens de erro do payload; lista vazia quando ele segue o contrato.
      def errors(name, data)
        schemer(name).validate(data.as_json).map { |error| error.fetch("error") }
      end

      def validate!(name, data)
        found = errors(name, data)
        raise InvalidPayload.new(name, found) if found.any?

        data
      end

      def schema(name)
        JSON.parse(root.join("schemas", "#{name}.json").read)
      end

      private

      def schemer(name)
        @schemers ||= {}
        @schemers[name.to_s] ||= JSONSchemer.schema(schema(name))
      end
    end
  end
end

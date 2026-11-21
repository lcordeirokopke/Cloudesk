module Routing
  # Valores possíveis de cada dimensão do when de uma regra, por marca: as opções do formulário de
  # regra do admin.
  #   channel:  ContactIdentity::CHANNELS;
  #   category: categorias da marca no classificador (config/routing/classifier.yml), na ordem do YAML;
  #   priority: urgências do classificador (high e normal);
  #   segment:  segmentos da marca em config/routing/dimensions.yml;
  #   language: idiomas da marca em config/routing/dimensions.yml;
  #   hours:    Routing::RuleDefinition::HOURS.
  #
  # O YAML é lido uma vez por processo. Marca ausente no YAML levanta KeyError.
  module Dimensions
    CONFIG_PATH = Rails.root.join("config/routing/dimensions.yml")
    PRIORITIES = %w[high normal].freeze

    class << self
      def for(brand)
        entry = config_for(brand.slug)
        {
          "channel" => ContactIdentity::CHANNELS,
          "category" => Classifier.categories(brand),
          "priority" => PRIORITIES,
          "segment" => entry.fetch("segments"),
          "language" => entry.fetch("languages"),
          "hours" => RuleDefinition::HOURS
        }
      end

      # Entrada da marca no YAML (segments e languages), pelo slug.
      def config_for(slug)
        config.fetch(slug) { raise KeyError, "marca sem dimensões em #{CONFIG_PATH}: #{slug}" }
      end

      private

      def config
        @config ||= YAML.safe_load_file(CONFIG_PATH).transform_values do |entry|
          { "segments" => Array(entry.fetch("segments")).freeze, "languages" => Array(entry.fetch("languages")).freeze }.freeze
        end.freeze
      end
    end
  end
end

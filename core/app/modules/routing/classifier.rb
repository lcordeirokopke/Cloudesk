module Routing
  # Classificador de entrada por palavras-chave. Do texto da mensagem (no e-mail, assunto e corpo)
  # define a categoria e a urgência da conversa, com as listas de config/routing/classifier.yml.
  #
  # O texto e as palavras passam pela mesma normalização: caixa baixa, sem acentos e com espaços
  # únicos. Cada palavra ou expressão casa inteira, com limites de palavra.
  #   categoria: cada categoria tem terms (peso 2) e context (peso 1). Quando duas palavras casam
  #              no mesmo trecho do texto, conta só a mais longa; no mesmo tamanho, a de maior peso
  #              e, depois, a da primeira categoria do YAML. A pontuação da categoria é a soma dos
  #              pesos das palavras que contam, cada palavra uma vez. Vence a maior pontuação; no
  #              empate, a primeira categoria do YAML. Sem nenhuma palavra, a categoria é nil.
  #   urgência:  high quando alguma palavra de urgência casa; senão, normal.
  #
  # O YAML é lido uma vez por processo.
  class Classifier
    CONFIG_PATH = Rails.root.join("config/routing/classifier.yml")
    WEIGHTS = { "terms" => 2, "context" => 1 }.freeze

    # category:         categoria, ou nil.
    # urgency:          high ou normal.
    # category_matches: palavras que contam, por categoria, só das categorias com alguma.
    # scores:           pontuação por categoria, só das categorias com alguma palavra.
    # urgency_matches:  palavras de urgência casadas.
    # version:          versão das listas da marca.
    Result = Data.define(:category, :urgency, :category_matches, :scores, :urgency_matches, :version)

    # Palavra normalizada de uma categoria, com o peso e a posição da categoria no YAML.
    Term = Data.define(:text, :category, :weight, :rank, :pattern)

    # Listas de uma marca, já normalizadas. categories é a lista de categorias na ordem do YAML.
    Lists = Data.define(:version, :categories, :terms, :urgency)

    # Trecho do texto casado por uma palavra.
    Span = Data.define(:start, :stop, :term)

    class << self
      def call(brand:, text:, subject: nil)
        lists = lists_for(brand)
        normalized = normalize([ subject, text ].compact.join(" "))

        counted = counted_terms(normalized, lists.terms)
        category_matches = lists.categories.to_h do |category|
          [ category, counted.select { |term| term.category == category }.map(&:text) ]
        end.reject { |_category, matched| matched.empty? }
        scores = category_matches.to_h do |category, _matched|
          [ category, counted.select { |term| term.category == category }.sum(&:weight) ]
        end
        urgency_matches = lists.urgency.select { |term| normalized.match?(pattern_for(term)) }

        Result.new(
          category: pick_category(scores),
          urgency: urgency_matches.any? ? "high" : "normal",
          category_matches: category_matches,
          scores: scores,
          urgency_matches: urgency_matches,
          version: lists.version
        )
      end

      def normalize(text)
        ActiveSupport::Inflector.transliterate(text.to_s.downcase).squish
      end

      private

      # Palavras que contam, na ordem do texto: de todos os trechos casados, os mais longos ficam e
      # os que se sobrepõem a eles saem. Cada palavra conta uma vez, mesmo casando em vários trechos.
      def counted_terms(normalized, terms)
        spans = terms.flat_map do |term|
          positions(normalized, term.pattern).map { |start| Span.new(start: start, stop: start + term.text.length, term: term) }
        end

        kept = []
        spans.sort_by { |span| [ -(span.stop - span.start), -span.term.weight, span.term.rank, span.start ] }.each do |span|
          kept << span if kept.none? { |other| span.start < other.stop && other.start < span.stop }
        end
        kept.sort_by(&:start).map(&:term).uniq
      end

      def positions(text, pattern)
        text.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }
      end

      # A ordem do Hash é a do YAML; max_by devolve o primeiro dos empatados.
      def pick_category(scores)
        return nil if scores.empty?

        scores.max_by { |_category, score| score }.first
      end

      def pattern_for(term)
        /(?<![[:alnum:]])#{Regexp.escape(term)}(?![[:alnum:]])/
      end

      def lists_for(brand)
        config.fetch(brand.slug) { raise KeyError, "marca sem palavras-chave em #{CONFIG_PATH}: #{brand.slug}" }
      end

      def config
        @config ||= load_config
      end

      def load_config
        YAML.safe_load_file(CONFIG_PATH).to_h do |slug, entry|
          categories = entry.fetch("categories")
          lists = Lists.new(
            version: Integer(entry.fetch("version")),
            categories: categories.keys.freeze,
            terms: build_terms(categories),
            urgency: normalize_terms(entry.fetch("urgency"))
          )
          [ slug, lists ]
        end.freeze
      end

      def build_terms(categories)
        categories.each_with_index.flat_map do |(category, lists), rank|
          unknown = lists.keys - WEIGHTS.keys
          raise KeyError, "listas desconhecidas na categoria #{category}: #{unknown.join(', ')}" if unknown.any?

          WEIGHTS.flat_map do |list, weight|
            normalize_terms(lists[list]).map do |text|
              Term.new(text: text, category: category, weight: weight, rank: rank, pattern: pattern_for(text))
            end
          end
        end.freeze
      end

      def normalize_terms(terms)
        Array(terms).map { |term| normalize(term) }.uniq.freeze
      end
    end
  end
end

require "rails_helper"

RSpec.describe Routing::Classifier do
  def classify(text, brand: infinitepay, subject: nil)
    described_class.call(brand: brand, text: text, subject: subject)
  end

  it "define a categoria pelas palavras casadas e grava as palavras, a pontuação e a versão" do
    result = classify("Meu repasse de ontem não caiu")

    expect(result).to have_attributes(category: "repasse", urgency: "normal", version: 2)
    expect(result.category_matches).to eq("repasse" => [ "repasse", "nao caiu" ])
    expect(result.scores).to eq("repasse" => 4)
    expect(result.urgency_matches).to eq([])
  end

  it "ignora caixa, acentos e espaços repetidos" do
    expect(classify("A   TRANSAÇÃO foi recusada").category).to eq("transacao")
    expect(classify("a transacao foi recusada").category).to eq("transacao")
    expect(classify("O dinheiro NAO   CAIU").category).to eq("repasse")
  end

  it "casa só a palavra inteira" do
    expect(classify("Eu repassei o valor").category).to be_nil
    expect(classify("Uso vários apps").category).to be_nil
  end

  describe "pontuação" do
    it "terms pesam 2 e context pesa 1" do
      result = classify("Fui cobrado de taxa na venda")

      expect(result.scores).to eq("taxas" => 3, "transacao" => 1)
      expect(result.category).to eq("taxas")
    end

    it "no mesmo trecho, conta só a expressão mais longa" do
      result = classify("O cliente foi cobrado duas vezes")

      expect(result.category_matches).to eq("transacao" => [ "cliente", "cobrado duas vezes" ])
      expect(result.scores).to eq("transacao" => 3)
    end

    it "a expressão mais longa leva o trecho para a categoria dela" do
      result = classify("Quanto é a taxa de antecipação?")

      expect(result.category_matches).to eq("taxas" => [ "taxa de antecipacao" ])
      expect(result.category).to eq("taxas")
    end

    it "a palavra conta uma vez, mesmo casando em vários trechos" do
      expect(classify("venda, venda e venda").scores).to eq("transacao" => 1)
    end

    it "card reader conta uma vez, sem somar reader" do
      expect(classify("My card reader", brand: jim).scores).to eq("card_reader" => 2)
    end

    it "no empate, vence a primeira categoria do YAML" do
      expect(classify("A taxa do repasse").category).to eq("repasse")
      expect(classify("O repasse da taxa").category).to eq("repasse")
    end
  end

  it "sem palavra casada, a categoria fica vazia" do
    result = classify("Bom dia, tudo bem?")

    expect(result.category).to be_nil
    expect(result.category_matches).to eq({})
    expect(result.scores).to eq({})
  end

  it "urgência high quando alguma palavra de urgência casa" do
    result = classify("Minha conta foi BLOQUEADA, é urgente")

    expect(result.urgency).to eq("high")
    expect(result.urgency_matches).to eq(%w[urgente bloqueada])
  end

  it "no e-mail, classifica pelo assunto e pelo corpo" do
    expect(classify("Podem verificar?", subject: "Fraude na maquininha")).to have_attributes(category: "maquininha", urgency: "high")
  end

  it "usa as palavras da marca" do
    expect(classify("My payout did not arrive, urgent", brand: jim)).to have_attributes(category: "payout", urgency: "high")
    expect(classify("Meu repasse", brand: jim).category).to be_nil
  end

  # Corpus de frases com a categoria e a urgência esperadas: o critério de qualidade das listas.
  describe "corpus" do
    corpus = YAML.safe_load_file(Rails.root.join("spec/fixtures/routing/classifier_corpus.yml"))

    corpus.each do |slug, entries|
      entries.each do |entry|
        expected = { category: entry["category"], urgency: entry.fetch("urgency", "normal") }
        label = [ entry["subject"], entry["text"] ].compact.join(" | ")

        it "#{slug}: #{label} => #{expected[:category].inspect}, #{expected[:urgency]}" do
          result = described_class.call(brand: Brand.find_by!(slug: slug), text: entry["text"], subject: entry["subject"])

          expect(category: result.category, urgency: result.urgency).to eq(expected),
            "pontuação: #{result.scores.inspect}; palavras: #{result.category_matches.inspect}; urgência: #{result.urgency_matches.inspect}"
        end
      end
    end
  end
end

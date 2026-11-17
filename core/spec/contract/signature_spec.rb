require "rails_helper"

# Os vetores de contracts/v1/signature-vectors.json são os mesmos que o pytest do agent_mock valida.
RSpec.describe Contract::Signature do
  vectors_file = JSON.parse(Contract::Schemas.root.join("signature-vectors.json").read)
  vectors = vectors_file.fetch("vectors")

  def arguments(vector)
    vector.slice("secret", "timestamp", "method", "path", "body").transform_keys(&:to_sym)
  end

  it "usa a janela de tempo do contrato" do
    expect(described_class::TOLERANCE_SECONDS).to eq(vectors_file.fetch("tolerance_seconds"))
  end

  vectors.each do |vector|
    it "assina o vetor: #{vector.fetch('description')}" do
      expect(described_class.sign(**arguments(vector))).to eq(vector.fetch("signature"))
    end
  end

  describe ".verify!" do
    let(:vector) { vectors.first }
    let(:signed_at) { Time.at(vector.fetch("timestamp").to_i) }

    def verify(vector, now:, **changes)
      described_class.verify!(**arguments(vector), signature: vector.fetch("signature"), now: now, **changes)
    end

    it "aceita a assinatura dentro da janela" do
      expect(verify(vector, now: signed_at)).to be(true)
      expect(verify(vector, now: signed_at + 300)).to be(true)
      expect(verify(vector, now: signed_at - 300)).to be(true)
    end

    it "recusa o reenvio antigo" do
      expect { verify(vector, now: signed_at + 301) }.to raise_error(described_class::Expired)
    end

    it "recusa timestamp adiantado além da janela" do
      expect { verify(vector, now: signed_at - 301) }.to raise_error(described_class::Expired)
    end

    it "recusa corpo, caminho, método, timestamp ou segredo diferentes do assinado" do
      changes = [
        { body: "#{vector.fetch('body')} " },
        { path: "/outro" },
        { method: "PUT" },
        { timestamp: (vector.fetch("timestamp").to_i + 1).to_s },
        { secret: "outro-segredo" }
      ]

      changes.each do |change|
        expect { verify(vector, now: signed_at, **change) }.to raise_error(described_class::Invalid)
      end
    end

    it "recusa chamada sem assinatura ou sem timestamp" do
      expect { verify(vector, now: signed_at, signature: nil) }.to raise_error(described_class::Invalid)
      expect { verify(vector, now: signed_at, timestamp: nil) }.to raise_error(described_class::Invalid)
      expect { verify(vector, now: signed_at, timestamp: "ontem") }.to raise_error(described_class::Invalid)
    end
  end

  describe ".headers" do
    it "produz os dois headers de uma chamada que .verify! aceita" do
      now = Time.at(1_794_578_531)
      headers = described_class.headers(secret: "s", method: "post", path: "/webhooks", body: "{}", now: now)

      expect(headers.keys).to eq(%w[X-Cloudesk-Timestamp X-Cloudesk-Signature])
      expect(
        described_class.valid?(
          secret: "s", method: "POST", path: "/webhooks", body: "{}", now: now + 10,
          timestamp: headers.fetch("X-Cloudesk-Timestamp"), signature: headers.fetch("X-Cloudesk-Signature")
        )
      ).to be(true)
    end
  end
end

require "rails_helper"

# Testes de contrato. Os schemas e os exemplos de contracts/ são os mesmos que o pytest do
# agent_mock valida: todo exemplo de valid/ passa e todo exemplo de invalid/ falha.
RSpec.describe Contract::Schemas do
  root = described_class.root
  schema_names = described_class.names

  it "encontra os schemas do contrato" do
    expect(schema_names).to eq(
      %w[action action-response context kafka.dlq-headers kafka.inbound-headers kafka.outbound-headers webhook.message-created]
    )
  end

  schema_names.each do |name|
    describe name do
      valid = root.join("examples", name, "valid").glob("*.json").sort
      invalid = root.join("examples", name, "invalid").glob("*.json").sort

      it "é um JSON Schema 2020-12 válido" do
        schema = described_class.schema(name)

        expect(schema.fetch("$schema")).to eq("https://json-schema.org/draft/2020-12/schema")
        expect(JSONSchemer.valid_schema?(schema)).to be(true)
      end

      it "tem exemplos válidos e inválidos" do
        expect(valid).not_to be_empty
        expect(invalid).not_to be_empty
      end

      valid.each do |path|
        it "aceita valid/#{path.basename}" do
          expect(described_class.errors(name, JSON.parse(path.read))).to eq([])
        end
      end

      invalid.each do |path|
        it "recusa invalid/#{path.basename}" do
          expect(described_class.valid?(name, JSON.parse(path.read))).to be(false)
        end
      end
    end
  end

  describe ".validate!" do
    it "devolve o payload que segue o contrato" do
      payload = JSON.parse(root.join("examples/action/valid/reply.json").read)

      expect(described_class.validate!("action", payload)).to equal(payload)
    end

    it "lança InvalidPayload com os erros do payload fora do contrato" do
      payload = JSON.parse(root.join("examples/action/invalid/reply-sem-text.json").read)

      expect { described_class.validate!("action", payload) }
        .to raise_error(Contract::Schemas::InvalidPayload) { |error| expect(error.errors).not_to be_empty }
    end
  end
end

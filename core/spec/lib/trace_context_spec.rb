require "rails_helper"

RSpec.describe TraceContext do
  let(:header) { "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" }

  describe ".parse" do
    it "lê trace_id, parent_id e flags de um header válido" do
      traceparent = described_class.parse(header)

      expect(traceparent.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      expect(traceparent.parent_id).to eq("00f067aa0ba902b7")
      expect(traceparent.flags).to eq("01")
      expect(traceparent.to_s).to eq(header)
    end

    it "devolve nil para header ausente ou inválido" do
      invalid = [
        nil,
        "",
        "abc",
        "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
        "00-#{'0' * 32}-00f067aa0ba902b7-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-#{'0' * 16}-01",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7"
      ]

      expect(invalid.map { |value| described_class.parse(value) }).to all(be_nil)
    end
  end

  describe ".generate" do
    it "produz um traceparent válido e distinto a cada chamada" do
      first = described_class.generate
      second = described_class.generate

      expect(described_class.parse(first.to_s)).to eq(first)
      expect(first.trace_id).not_to eq(second.trace_id)
    end
  end

  describe ".continue" do
    it "mantém o trace_id do header e gera um parent_id próprio" do
      traceparent = described_class.continue(header)

      expect(traceparent.trace_id).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
      expect(traceparent.parent_id).not_to eq("00f067aa0ba902b7")
      expect(described_class.parse(traceparent.to_s)).to eq(traceparent)
    end

    it "inicia um trace quando o header é inválido" do
      expect(described_class.parse(described_class.continue("lixo").to_s)).to be_present
    end
  end
end

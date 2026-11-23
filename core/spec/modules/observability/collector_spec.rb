require "rails_helper"

RSpec.describe Observability::Collector do
  let(:registry) { Observability::Registry.build }

  # Leitor que conta as chamadas e, com error, falha em todas.
  let(:fake_reader) do
    Class.new do
      attr_reader :calls

      def initialize(error: nil)
        @error = error
        @calls = 0
      end

      def collect
        @calls += 1
        raise @error if @error
      end
    end
  end

  it "o erro de um leitor não impede os outros e conta em cloudesk_metrics_collect_errors_total" do
    output = StringIO.new
    readers = { "latency" => fake_reader.new, "queue" => fake_reader.new(error: RuntimeError.new("banco fora")),
                "cockpit" => fake_reader.new }
    collector = described_class.new(registry: registry, logger: Logger.new(output), readers: readers)

    collector.collect_once
    collector.collect_once

    expect(readers.values.map(&:calls)).to eq([ 2, 2, 2 ])
    expect(registry.value(:cloudesk_metrics_collect_errors_total, reader: "queue")).to eq(2)
    expect(registry.value(:cloudesk_metrics_collect_errors_total, reader: "latency")).to eq(0)
    expect(output.string).to include("leitor queue falhou: RuntimeError: banco fora")
    %w[latency queue cockpit].each do |name|
      expect(registry.value(:cloudesk_metrics_collect_duration_seconds, reader: name)).to be >= 0
    end
  end

  it "usa os três leitores do serviço" do
    collector = described_class.new(registry: registry, logger: Logger.new(IO::NULL))

    expect(collector.readers.keys).to eq(%w[latency queue cockpit])
    expect(collector.readers.values.map(&:class)).to eq(
      [ Observability::LatencyReader, Observability::QueueReader, Observability::CockpitReader ]
    )
  end

  it "coleta com os leitores reais sem erro" do
    collector = described_class.new(registry: registry, logger: Logger.new(IO::NULL))

    collector.collect_once

    %w[latency queue cockpit].each do |name|
      expect(registry.value(:cloudesk_metrics_collect_errors_total, reader: name)).to eq(0), name
    end
  end
end

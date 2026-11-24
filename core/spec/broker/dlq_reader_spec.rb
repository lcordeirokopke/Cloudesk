require "broker_helper"

RSpec.describe Broker::DlqReader, broker: true do
  # Mensagem lida pelo Karafka::Admin, com os campos que o leitor usa.
  DlqReaderSpecMessage = Struct.new(:partition, :offset, :raw_key, :raw_headers, :raw_payload, :timestamp, keyword_init: true)

  # Karafka::Admin falso: mensagens por partição de agent.dlq.
  class DlqReaderSpecAdmin
    attr_reader :reads

    def initialize(partitions)
      @partitions = partitions
      @reads = []
    end

    def topic_info(_topic)
      { partition_count: @partitions.size }
    end

    def read_watermark_offsets(_topic, partition)
      messages = @partitions.fetch(partition)
      messages.empty? ? [ 0, 0 ] : [ messages.first.offset, messages.last.offset + 1 ]
    end

    def read_topic(topic, partition, count, start_offset = -1)
      @reads << [ topic, partition, count, start_offset ]
      messages = @partitions.fetch(partition)
      start_offset == -1 ? messages.last(count) : messages.select { |message| message.offset >= start_offset }.first(count)
    end
  end

  let(:failed_at) { "2026-11-23T14:00:00.000Z" }
  let(:action) { contract_example("action", "reply") }

  def message(partition, offset, headers: { "brand" => "infinitepay", "dlq_reason" => "core_rejected" }, payload: action)
    DlqReaderSpecMessage.new(partition: partition, offset: offset, raw_key: "conversa-#{offset}",
                     raw_headers: headers.merge("dlq_failed_at" => failed_at), raw_payload: payload,
                     timestamp: Time.utc(2026, 11, 23, 14))
  end

  it "lê as últimas mensagens de cada partição do tópico" do
    admin = DlqReaderSpecAdmin.new([ [ message(0, 0), message(0, 1), message(0, 2) ], [ message(1, 0) ] ])

    found = described_class.new(admin: admin).recent(limit: 2)

    expect(found.map { |item| [ item.partition, item.offset ] }).to eq([ [ 0, 1 ], [ 0, 2 ], [ 1, 0 ] ])
    expect(admin.reads).to eq([ [ "agent.dlq", 0, 2, -1 ], [ "agent.dlq", 1, 2, -1 ] ])
  end

  it "entrega chave, headers, valor e os campos da ação" do
    admin = DlqReaderSpecAdmin.new([ [ message(0, 4, headers: { "brand" => "jim", "traceparent" => [ "a", "b" ] }) ] ])

    item = described_class.new(admin: admin).recent(limit: 1).first

    expect(item.brand).to eq("jim")
    expect(item.headers).to include("traceparent" => "b", "dlq_failed_at" => failed_at)
    expect(item.to_h).to include(
      "partition" => 0, "offset" => 4, "key" => "conversa-4", "value" => action,
      "type" => "reply", "inbound_event_id" => JSON.parse(action).fetch("inbound_event_id"),
      "timestamp" => "2026-11-23T14:00:00.000Z"
    )
  end

  it "aceita mensagem sem brand e valor que não é JSON" do
    admin = DlqReaderSpecAdmin.new([ [ message(0, 0, headers: { "dlq_reason" => "invalid_message" }, payload: "não é json") ] ])

    item = described_class.new(admin: admin).recent(limit: 1).first

    expect(item.brand).to be_nil
    expect(item.reason).to eq("invalid_message")
    expect(item.to_h).to include("value" => "não é json", "type" => nil, "inbound_event_id" => nil)
  end

  it "acha a mensagem pela partição e pelo offset" do
    admin = DlqReaderSpecAdmin.new([ [ message(0, 0) ], [ message(1, 5), message(1, 6) ] ])

    item = described_class.new(admin: admin).find(partition: 1, offset: 6)

    expect([ item.partition, item.offset ]).to eq([ 1, 6 ])
  end

  it "devolve nil para posição inexistente" do
    reader = described_class.new(admin: DlqReaderSpecAdmin.new([ [ message(0, 3) ] ]))

    expect(reader.find(partition: 0, offset: 4)).to be_nil
    expect(reader.find(partition: 0, offset: 2)).to be_nil
    expect(reader.find(partition: 1, offset: 0)).to be_nil
  end
end

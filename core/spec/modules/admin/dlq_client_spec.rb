require "rails_helper"

RSpec.describe Admin::DlqClient do
  let(:brand) { infinitepay }
  let(:secret) { DlqHelpers::ENVIRONMENT.fetch("BROKER_DLQ_SECRET") }

  def signed?(request, method:, path:, body: "")
    Contract::Signature.valid?(
      secret: secret, timestamp: request_header(request, "X-Cloudesk-Timestamp"),
      signature: request_header(request, "X-Cloudesk-Signature"), method: method, path: path, body: body
    )
  end

  describe ".list" do
    it "chama GET /dlq/messages com marca e limite, assinado sobre o caminho com a query string" do
      message = dlq_listed_message(partition: 0, offset: 3, key: "conversa")
      stub_dlq_list(brand, [ message ], limit: 20)

      expect(described_class.list(brand: brand, limit: 20)).to eq([ message ])
      expect(WebMock).to(have_requested(:get, dlq_url("/dlq/messages")).with(query: { brand: "infinitepay", limit: "20" }) do |request|
        signed?(request, method: "GET", path: "/dlq/messages?brand=infinitepay&limit=20") &&
          request_header(request, "traceparent").to_s.start_with?("00-")
      end)
    end

    it "usa limite 50 por padrão" do
      stub_dlq_list(brand, [])

      expect(described_class.list(brand: brand)).to eq([])
    end
  end

  describe ".reprocess" do
    it "chama POST com a marca no corpo, assinado sobre o corpo, e devolve a resposta" do
      stub_dlq_reprocess(1, 7)

      result = described_class.reprocess(brand: brand, partition: 1, offset: 7)

      expect(result.fetch("destination")).to eq("topic" => "agent.outbound", "partition" => 2, "offset" => 40)
      expect(WebMock).to(have_requested(:post, dlq_url("/dlq/messages/1/7/reprocess")).with do |request|
        request.body == '{"brand":"infinitepay"}' &&
          signed?(request, method: "POST", path: "/dlq/messages/1/7/reprocess", body: request.body)
      end)
    end

    it "levanta Admin::DlqClient::Error com o status e o erro do Broker" do
      stub_request(:post, dlq_url("/dlq/messages/1/7/reprocess"))
        .to_return(status: 503, body: '{"status":"error","error":"kafka_unavailable","message":"Kafka não confirmou"}')

      expect { described_class.reprocess(brand: brand, partition: 1, offset: 7) }
        .to raise_error(Admin::DlqClient::Error, "Broker respondeu 503: kafka_unavailable: Kafka não confirmou")
    end
  end

  it "levanta Admin::DlqClient::Error no erro de rede e no tempo esgotado" do
    stub_request(:get, dlq_url("/dlq/messages")).with(query: hash_including({})).to_raise(Errno::ECONNREFUSED)
    expect { described_class.list(brand: brand) }.to raise_error(Admin::DlqClient::Error, /Broker indisponível/)

    stub_request(:get, dlq_url("/dlq/messages")).with(query: hash_including({})).to_timeout
    expect { described_class.list(brand: brand) }.to raise_error(Admin::DlqClient::Error, /Broker indisponível/)
  end

  it "usa 2 s de conexão e 10 s de leitura" do
    stub_dlq_list(brand, [])
    allow(Net::HTTP).to receive(:start).and_call_original

    described_class.list(brand: brand)

    expect(Net::HTTP).to have_received(:start).with("broker-dlq.test", 3000, hash_including(open_timeout: 2, read_timeout: 10))
  end
end

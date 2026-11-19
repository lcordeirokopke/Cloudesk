require "rails_helper"

RSpec.describe Agents::BrokerClient do
  let(:body) { { "event_id" => SecureRandom.uuid_v7, "type" => "message.created" }.to_json }
  let(:traceparent) { TraceContext.generate.to_s }

  def deliver(**options)
    described_class.deliver(body: body, traceparent: traceparent, **options)
  end

  let(:requests) { [] }

  def last_request
    requests.last
  end

  # Responde status e guarda cada requisição recebida.
  def stub_broker(url = broker_webhook_url, status: 202)
    stub_request(:post, url).to_return do |request|
      requests << request
      { status: status }
    end
  end

  describe "requisição" do
    before { stub_broker }

    it "envia POST JSON com o corpo recebido, sem nova serialização, e o traceparent" do
      deliver

      expect(a_request(:post, broker_webhook_url).with(
        body: body, headers: { "Content-Type" => "application/json", "traceparent" => traceparent }
      )).to have_been_made.once
    end

    it "assina o corpo enviado com o segredo do Broker e o caminho da URL" do
      deliver

      expect(verify_broker_signature!(last_request)).to be(true)
      expect(request_header(last_request, "X-Cloudesk-Timestamp")).to match(/\A\d+\z/)
    end

    it "assina o caminho com a query string" do
      url = "#{broker_webhook_url}?origem=core"
      stub_broker(url)
      ENV["BROKER_WEBHOOK_URL"] = url

      deliver

      expect(verify_broker_signature!(last_request, path: "/webhooks/message-created?origem=core")).to be(true)
    ensure
      ENV["BROKER_WEBHOOK_URL"] = broker_webhook_url
    end

    it "gera timestamp e assinatura próprios em cada envio" do
      now = Time.current
      deliver(now: now)
      first = last_request
      deliver(now: now + 7)
      second = last_request

      expect(request_header(second, "X-Cloudesk-Timestamp").to_i).to eq(request_header(first, "X-Cloudesk-Timestamp").to_i + 7)
      expect(request_header(second, "X-Cloudesk-Signature")).not_to eq(request_header(first, "X-Cloudesk-Signature"))
      expect(verify_broker_signature!(second, now: now + 7)).to be(true)
    end

    it "não confere com outro segredo" do
      deliver

      expect do
        Contract::Signature.verify!(
          secret: "outro-segredo", timestamp: request_header(last_request, "X-Cloudesk-Timestamp"),
          signature: request_header(last_request, "X-Cloudesk-Signature"), method: "POST",
          path: "/webhooks/message-created", body: body
        )
      end.to raise_error(Contract::Signature::Invalid)
    end
  end

  describe "resposta" do
    [ 200, 201, 202, 204 ].each do |status|
      it "trata #{status} como sucesso" do
        stub_request(:post, broker_webhook_url).to_return(status: status)

        expect(deliver.code.to_i).to eq(status)
      end
    end

    [ 408, 429, 500, 502, 503, 504 ].each do |status|
      it "trata #{status} como transitório" do
        stub_request(:post, broker_webhook_url).to_return(status: status)

        expect { deliver }.to raise_error(Agents::WebhookError::Transient, /#{status}/)
      end
    end

    [ 400, 401, 403, 404, 409, 422, 301, 302 ].each do |status|
      it "trata #{status} como permanente" do
        stub_request(:post, broker_webhook_url).to_return(status: status, body: "recusado")

        expect { deliver }.to raise_error(Agents::WebhookError::Permanent, /#{status}: recusado/)
      end
    end
  end

  describe "erro de rede" do
    {
      "conexão recusada" => Errno::ECONNREFUSED,
      "conexão interrompida" => Errno::ECONNRESET,
      "host inalcançável" => Errno::EHOSTUNREACH,
      "nome não resolvido" => SocketError.new("getaddrinfo: Name or service not known"),
      "timeout de leitura" => Net::ReadTimeout
    }.each do |description, error|
      it "trata #{description} como transitório" do
        stub_request(:post, broker_webhook_url).to_raise(error)

        expect { deliver }.to raise_error(Agents::WebhookError::Transient, /Broker indisponível/)
      end
    end

    it "trata o timeout de conexão como transitório" do
      stub_request(:post, broker_webhook_url).to_timeout

      expect { deliver }.to raise_error(Agents::WebhookError::Transient, /Broker indisponível/)
    end
  end
end

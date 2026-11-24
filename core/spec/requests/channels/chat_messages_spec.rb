require "rails_helper"

RSpec.describe "Entrada JSON do chat", type: :request do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:app_user_id) { identity_of(contact, "chat") }
  let(:path) { "/channels/chat/messages" }

  def body_for(**attributes)
    { brand: "infinitepay", app_user_id: app_user_id, client_message_id: "client-#{SecureRandom.hex(4)}",
      text: "Minha maquininha não liga" }.merge(attributes).to_json
  end

  def post_signed(body, now: Time.now, secret: ENV.fetch("CHAT_SIGNING_SECRET"))
    headers = Contract::Signature.headers(secret: secret, method: "POST", path: path, body: body, now: now)
    post path, params: body, headers: headers.merge("Content-Type" => "application/json")
  end

  it "grava a mensagem e responde conversa, sequência e o stream assinado do lojista" do
    post_signed(body_for(client_message_id: "client-1"))

    expect(response).to have_http_status(:ok)
    json = response.parsed_body
    Tenancy.with_brand(brand) do
      message = Message.find_by!(channel: "chat", external_id: "client-1")
      expect(json).to eq(
        "conversation_id" => message.conversation_id,
        "sequence" => message.sequence,
        "stream" => Channels::Chat.signed_stream_name(contact)
      )
      expect(message.body).to eq("Minha maquininha não liga")
    end
    expect(Turbo::StreamsChannel.verified_stream_name(json["stream"])).to eq(
      Turbo::StreamsChannel.send(:stream_name_from, Channels::Chat.streamables(contact))
    )
  end

  it "o reenvio do mesmo client_message_id devolve a mesma mensagem" do
    body = body_for(client_message_id: "client-repetido")
    post_signed(body)
    first = response.parsed_body

    expect { post_signed(body) }.not_to(change { Tenancy.with_brand(brand) { Message.count } })
    expect(response.parsed_body).to eq(first)
  end

  it "aceita anexos só com metadados" do
    post_signed(body_for(client_message_id: "client-anexo", text: "",
                         attachments: [ { kind: "image", filename: "foto.jpg", content_type: "image/jpeg", size: 2048 } ]))

    expect(response).to have_http_status(:ok)
    Tenancy.with_brand(brand) do
      expect(Message.find_by!(external_id: "client-anexo")).to have_attributes(
        body: "[imagem enviada]",
        attachments: [ { "kind" => "image", "filename" => "foto.jpg", "content_type" => "image/jpeg", "size" => 2048 } ]
      )
    end
  end

  it "recusa a assinatura inválida com 401" do
    post_signed(body_for, secret: "outro-segredo")

    expect(response).to have_http_status(:unauthorized)
  end

  it "recusa a assinatura vencida com 401" do
    post_signed(body_for, now: Time.now - 301)

    expect(response).to have_http_status(:unauthorized)
  end

  it "recusa a chamada sem assinatura com 401" do
    post path, params: body_for, headers: { "Content-Type" => "application/json" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "recusa marca desconhecida e corpo incompleto com 422" do
    post_signed(body_for(brand: "outra"))
    expect(response).to have_http_status(:unprocessable_content)

    post_signed(body_for(client_message_id: ""))
    expect(response).to have_http_status(:unprocessable_content)

    post_signed(body_for(text: "", attachments: []))
    expect(response).to have_http_status(:unprocessable_content)
  end

  describe "limite de taxa" do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(Rails).to receive(:cache).and_return(store)
      allow_any_instance_of(Brand).to receive(:inbound_rate_limit_per_second).and_return(2)
    end

    around { |example| travel_to(Time.zone.parse("2026-11-23 14:00:00")) { example.run } }

    it "dentro do limite, grava e responde 200" do
      2.times { |index| post_signed(body_for(client_message_id: "client-limite-#{index}")) }

      expect(response).to have_http_status(:ok)
      expect(Tenancy.with_brand(brand) { Message.where(channel: "chat", external_id: %w[client-limite-0 client-limite-1]).count }).to eq(2)
    end

    it "acima do limite, responde 429 com Retry-After: 1 e não grava" do
      2.times { |index| post_signed(body_for(client_message_id: "client-limite-#{index}")) }

      expect { post_signed(body_for(client_message_id: "client-limite-2")) }
        .not_to(change { [ Tenancy.with_brand(brand) { [ Message.count, AuditEvent.count ] }, SolidQueue::Job.count ] })
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(response.parsed_body).to eq("error" => "rate_limited")
    end
  end
end

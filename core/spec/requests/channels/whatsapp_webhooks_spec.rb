require "rails_helper"

RSpec.describe "Webhook do WhatsApp", type: :request do
  let(:brand) { infinitepay }
  let(:number) { brand_channel(brand, "whatsapp") }
  let(:contact) { seed_contact(brand) }
  let(:wa_id) { identity_of(contact, "whatsapp").delete_prefix("+") }

  def post_payload(payload, signature: :valid)
    body = payload.to_json
    header = signature == :valid ? Channels::Whatsapp::Signature.sign(body) : signature
    headers = { "Content-Type" => "application/json" }
    headers[Channels::Whatsapp::Signature::HEADER] = header if header
    post "/channels/whatsapp/webhook", params: body, headers: headers
  end

  def messages_of(external_ids)
    Tenancy.with_brand(brand) { Message.where(channel: "whatsapp", external_id: external_ids).order(:sequence).to_a }
  end

  describe "GET de verificação" do
    it "devolve o hub.challenge com o token certo" do
      get "/channels/whatsapp/webhook", params: {
        "hub.mode" => "subscribe", "hub.verify_token" => ENV.fetch("WHATSAPP_VERIFY_TOKEN"), "hub.challenge" => "1158201444"
      }

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("1158201444")
      expect(response.media_type).to eq("text/plain")
    end

    it "recusa o token errado com 403" do
      get "/channels/whatsapp/webhook", params: { "hub.mode" => "subscribe", "hub.verify_token" => "errado", "hub.challenge" => "1" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "assinatura" do
    let(:payload) { whatsapp_payload(phone_number_id: number.value, messages: [ whatsapp_text(from: wa_id, text: "oi") ]) }

    it "aceita a assinatura válida" do
      post_payload(payload)

      expect(response).to have_http_status(:ok)
    end

    it "recusa a assinatura inválida com 401, sem gravar" do
      expect { post_payload(payload, signature: "sha256=#{'0' * 64}") }
        .not_to(change { Tenancy.with_brand(brand) { Message.count } })

      expect(response).to have_http_status(:unauthorized)
    end

    it "recusa a assinatura ausente com 401" do
      post_payload(payload, signature: nil)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "mensagens" do
    it "grava a mensagem de texto do lojista pelo número da marca, com nome, wamid e identidade" do
      message = whatsapp_text(from: wa_id, text: "Meu repasse não caiu", id: "wamid.texto")
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: [ message ],
                                    contacts: [ { "profile" => { "name" => "Outro Nome" }, "wa_id" => wa_id } ]))

      expect(response).to have_http_status(:ok)
      recorded = messages_of("wamid.texto").sole
      expect(recorded).to have_attributes(body: "Meu repasse não caiu", author: "customer", brand_channel_id: number.id)
      Tenancy.with_brand(brand) { expect(recorded.conversation.contact_id).to eq(contact.id) }
    end

    it "lojista novo recebe o nome do perfil do WhatsApp" do
      post_payload(whatsapp_payload(
        phone_number_id: number.value,
        messages: [ whatsapp_text(from: "5511977776666", text: "oi", id: "wamid.novo") ],
        contacts: [ { "profile" => { "name" => "Sheena Nelson" }, "wa_id" => "5511977776666" } ]
      ))

      Tenancy.with_brand(brand) do
        expect(messages_of("wamid.novo").sole.conversation.contact.name).to eq("Sheena Nelson")
        expect(ContactIdentity.find_by!(channel: "whatsapp", value: "+5511977776666")).to be_present
      end
    end

    it "imagem com legenda guarda os metadados e a legenda como texto" do
      image = { "from" => wa_id, "id" => "wamid.imagem", "timestamp" => "1749416383", "type" => "image",
                "image" => { "id" => "media-1", "mime_type" => "image/jpeg", "sha256" => "abc", "caption" => "Comprovante" } }
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: [ image ]))

      expect(messages_of("wamid.imagem").sole).to have_attributes(
        body: "Comprovante", attachments: [ { "kind" => "image", "content_type" => "image/jpeg" } ]
      )
    end

    it "imagem sem legenda recebe o texto padrão" do
      image = { "from" => wa_id, "id" => "wamid.semlegenda", "timestamp" => "1749416383", "type" => "image",
                "image" => { "id" => "media-2", "mime_type" => "image/png", "sha256" => "abc" } }
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: [ image ]))

      expect(messages_of("wamid.semlegenda").sole.body).to eq("[imagem enviada]")
    end

    it "documento guarda nome do arquivo e tipo" do
      document = { "from" => wa_id, "id" => "wamid.documento", "timestamp" => "1749416383", "type" => "document",
                   "document" => { "id" => "media-3", "mime_type" => "application/pdf", "sha256" => "abc", "filename" => "extrato.pdf" } }
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: [ document ]))

      expect(messages_of("wamid.documento").sole).to have_attributes(
        body: "[documento enviado]",
        attachments: [ { "kind" => "document", "filename" => "extrato.pdf", "content_type" => "application/pdf" } ]
      )
    end

    it "tipo sem suporte recebe o texto padrão de outro conteúdo" do
      sticker = { "from" => wa_id, "id" => "wamid.sticker", "timestamp" => "1749416383", "type" => "sticker",
                  "sticker" => { "id" => "media-4" } }
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: [ sticker ]))

      expect(messages_of("wamid.sticker").sole).to have_attributes(body: "[conteúdo enviado]", attachments: [ { "kind" => "other" } ])
    end

    it "ignora statuses" do
      payload = whatsapp_payload(phone_number_id: number.value, messages: [])
      payload["entry"][0]["changes"][0]["value"].delete("messages")
      payload["entry"][0]["changes"][0]["value"]["statuses"] = [
        { "id" => "wamid.x", "status" => "delivered", "timestamp" => "1749416383", "recipient_id" => wa_id }
      ]

      expect { post_payload(payload) }.not_to(change { Tenancy.with_brand(brand) { Message.count } })
      expect(response).to have_http_status(:ok)
    end

    it "phone_number_id desconhecido recebe 200 e não grava" do
      payload = whatsapp_payload(phone_number_id: "999", messages: [ whatsapp_text(from: wa_id, text: "oi") ])

      expect { post_payload(payload) }.not_to(change { Tenancy.with_brand(brand) { Message.count } })
      expect(response).to have_http_status(:ok)
    end

    it "grava todas as mensagens de um payload, na ordem" do
      messages = [
        whatsapp_text(from: wa_id, text: "primeira", id: "wamid.a"),
        whatsapp_text(from: wa_id, text: "segunda", id: "wamid.b")
      ]
      post_payload(whatsapp_payload(phone_number_id: number.value, messages: messages))

      expect(messages_of(%w[wamid.a wamid.b]).map(&:body)).to eq(%w[primeira segunda])
    end

    it "reenvio do mesmo wamid recebe 200 e não grava de novo" do
      payload = whatsapp_payload(phone_number_id: number.value, messages: [ whatsapp_text(from: wa_id, text: "oi", id: "wamid.reenvio") ])
      post_payload(payload)

      expect { post_payload(payload) }.not_to(change { Tenancy.with_brand(brand) { [ Message.count, AuditEvent.count ] } })
      expect(response).to have_http_status(:ok)
    end
  end

  describe "limite de taxa" do
    let(:store) { ActiveSupport::Cache::MemoryStore.new }
    let(:jim_number) { brand_channel(jim, "whatsapp") }
    let(:jim_wa_id) { identity_of(seed_contact(jim), "whatsapp").delete_prefix("+") }

    before do
      allow(Rails).to receive(:cache).and_return(store)
      limits = { "infinitepay" => 2, "jim" => 500 }
      allow_any_instance_of(Brand).to receive(:inbound_rate_limit_per_second) { |record| limits.fetch(record.slug) }
    end

    around { |example| travel_to(Time.zone.parse("2026-11-23 14:00:00")) { example.run } }

    def payload_for(*ids)
      whatsapp_payload(phone_number_id: number.value, messages: ids.map { |id| whatsapp_text(from: wa_id, text: "oi", id: id) })
    end

    def recorded_counts
      [ Tenancy.with_brand(brand) { [ Message.count, AuditEvent.count ] }, Tenancy.with_brand(jim) { [ Message.count, AuditEvent.count ] },
        SolidQueue::Job.count ]
    end

    it "dentro do limite, grava e responde 200" do
      post_payload(payload_for("wamid.limite-1", "wamid.limite-2"))

      expect(response).to have_http_status(:ok)
      expect(messages_of(%w[wamid.limite-1 wamid.limite-2]).size).to eq(2)
    end

    it "acima do limite, responde 429 com Retry-After: 1, sem mensagem, audit_event nem job" do
      post_payload(payload_for("wamid.limite-1", "wamid.limite-2"))

      expect { post_payload(payload_for("wamid.limite-3")) }.not_to(change { recorded_counts })
      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("1")
      expect(response.parsed_body).to eq("error" => "rate_limited")
      expect(messages_of(%w[wamid.limite-3])).to be_empty
    end

    it "payload com duas marcas em que uma passa do limite não grava nada" do
      payload = payload_for("wamid.ip-1", "wamid.ip-2", "wamid.ip-3")
      jim_entry = whatsapp_payload(phone_number_id: jim_number.value,
                                   messages: [ whatsapp_text(from: jim_wa_id, text: "hi", id: "wamid.jim-1") ])
      payload["entry"].unshift(jim_entry["entry"].first)

      expect { post_payload(payload) }.not_to(change { recorded_counts })
      expect(response).to have_http_status(:too_many_requests)
      expect(Tenancy.with_brand(jim) { Message.where(external_id: "wamid.jim-1").count }).to eq(0)
    end

    it "volta a aceitar no segundo seguinte" do
      post_payload(payload_for("wamid.limite-1", "wamid.limite-2", "wamid.limite-3"))
      expect(response).to have_http_status(:too_many_requests)

      travel 1.second
      post_payload(payload_for("wamid.limite-4"))

      expect(response).to have_http_status(:ok)
      expect(messages_of(%w[wamid.limite-4]).size).to eq(1)
    end
  end
end

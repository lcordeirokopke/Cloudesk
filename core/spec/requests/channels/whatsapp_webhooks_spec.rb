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
end

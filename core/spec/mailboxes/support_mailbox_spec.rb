require "rails_helper"

RSpec.describe SupportMailbox, type: :mailbox do
  include ActionMailbox::TestHelper

  let(:brand) { infinitepay }
  let(:contact) { seed_contact(brand) }
  let(:email) { identity_of(contact, "email") }

  def receive_mail(mail)
    receive_inbound_email_from_source(mail.to_s)
  end

  def message_for(message_id)
    Tenancy.with_brand(brand) { Message.find_by!(channel: "email", external_id: message_id) }
  end

  def event_payload(message)
    Tenancy.with_brand(brand) { AuditEvent.find_by!(action: "message.created", target_id: message.id).payload }
  end

  def text_mail(body:, message_id:, from: email, to: "suporte@infinitepay.test")
    Mail.new do
      from from
      to to
      subject "Repasse atrasado"
      message_id "<#{message_id}>"
      body body
      content_type "text/plain; charset=UTF-8"
    end
  end

  it "grava a mensagem do lojista das seeds pelo e-mail de suporte, com assunto e identidade no payload" do
    inbound_email = receive_mail(text_mail(body: "Meu repasse de ontem não caiu", message_id: "texto@lojista.test",
                                      from: email.upcase))

    expect(inbound_email).to be_delivered
    message = message_for("texto@lojista.test")
    expect(message).to have_attributes(body: "Meu repasse de ontem não caiu", author: "customer",
                                       brand_channel_id: BrandChannel.lookup("email", "suporte@infinitepay.test").id)
    Tenancy.with_brand(brand) { expect(message.conversation.contact_id).to eq(contact.id) }
    payload = event_payload(message)
    expect(payload["received_at"]).to eq(inbound_email.created_at.utc.iso8601(3))
    expect(payload["payload"]).to include("subject" => "Repasse atrasado", "identity" => email,
                                          "external_id" => "texto@lojista.test")
  end

  it "remove o trecho citado da resposta" do
    body = <<~TEXT
      Ainda não caiu.
      Podem verificar?

      On Mon, Nov 17, 2026 at 10:00 AM Suporte <suporte@infinitepay.test> wrote:
      > Seu repasse cai hoje.
      > Obrigado.
    TEXT
    receive_mail(text_mail(body: body, message_id: "citado@lojista.test"))

    expect(message_for("citado@lojista.test").body).to eq("Ainda não caiu.\nPodem verificar?")
  end

  it "remove o trecho a partir de \"Em … escreveu:\" e as linhas com >" do
    body = "Obrigado!\n> linha citada solta\nEm seg., 17 de nov. de 2026 às 10:00, Suporte escreveu:\n> resposta antiga\n"
    receive_mail(text_mail(body: body, message_id: "pt@lojista.test"))

    expect(message_for("pt@lojista.test").body).to eq("Obrigado!")
  end

  it "usa o HTML sem tags quando não existe parte de texto" do
    from = email
    mail = Mail.new do
      from from
      to "suporte@infinitepay.test"
      subject "Taxas"
      message_id "<html@lojista.test>"
      content_type "text/html; charset=UTF-8"
      body "<html><body><p>Quais são as <b>taxas</b> do crédito?</p></body></html>"
    end
    receive_mail(mail)

    expect(message_for("html@lojista.test").body).to eq("Quais são as taxas do crédito?")
  end

  it "guarda os metadados dos anexos e usa o texto padrão quando não há texto" do
    from = email
    mail = Mail.new do
      from from
      to "suporte@infinitepay.test"
      subject "Comprovante"
      message_id "<anexo@lojista.test>"
      text_part { body "" }
      add_file filename: "comprovante.pdf", content: "%PDF-1.4 conteúdo", mime_type: "application/pdf"
      add_file filename: "foto.jpg", content: "jpeg", mime_type: "image/jpeg"
    end
    receive_mail(mail)

    message = message_for("anexo@lojista.test")
    expect(message.body).to eq("[documento enviado]")
    expect(message.attachments).to contain_exactly(
      { "kind" => "document", "filename" => "comprovante.pdf", "content_type" => "application/pdf", "size" => "%PDF-1.4 conteúdo".bytesize },
      { "kind" => "image", "filename" => "foto.jpg", "content_type" => "image/jpeg", "size" => 4 }
    )
  end

  it "lojista desconhecido recebe o nome de exibição do From" do
    mail = Mail.new do
      from "Maria Souza <maria.nova@example.com>"
      to "suporte@infinitepay.test"
      subject "Oi"
      message_id "<nova@lojista.test>"
      body "Quero abrir conta"
      content_type "text/plain; charset=UTF-8"
    end
    receive_mail(mail)

    Tenancy.with_brand(brand) { expect(message_for("nova@lojista.test").conversation.contact.name).to eq("Maria Souza") }
  end

  it "sem nome de exibição, o lojista novo recebe a parte local do endereço" do
    receive_mail(text_mail(body: "Oi", message_id: "local@lojista.test", from: "joao.local@example.com"))

    Tenancy.with_brand(brand) { expect(message_for("local@lojista.test").conversation.contact.name).to eq("joao.local") }
  end

  it "e-mail sem destinatário de suporte é marcado como bounced, sem gravar e sem enviar e-mail" do
    ActionMailer::Base.deliveries.clear

    inbound_email = nil
    expect do
      inbound_email = receive_mail(text_mail(body: "Oi", message_id: "sem-marca@lojista.test", to: "outro@example.com"))
    end.not_to(change { Tenancy.with_brand(brand) { Message.count } })

    expect(inbound_email).to be_bounced
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end

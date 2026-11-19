# Apoio aos testes dos canais: chamadas HTTP de saída simuladas pelo webmock, segredos fixos dos
# canais e construtores de mensagens de entrada.
require "webmock/rspec"

WebMock.disable_net_connect!

module ChannelHelpers
  # Valores dos testes; substituem os do ambiente do contêiner.
  ENVIRONMENT = {
    "WHATSAPP_APP_SECRET" => "whatsapp-app-secret-de-teste",
    "WHATSAPP_VERIFY_TOKEN" => "whatsapp-verify-token-de-teste",
    "WHATSAPP_ACCESS_TOKEN" => "whatsapp-access-token-de-teste",
    "WHATSAPP_API_URL" => "http://whatsapp.test/v1",
    "CHAT_SIGNING_SECRET" => "chat-signing-secret-de-teste",
    "MAILPIT_WEBHOOK_USER" => "mailpit",
    "MAILPIT_WEBHOOK_PASSWORD" => "mailpit-password-de-teste",
    "MAILPIT_API_URL" => "http://mailpit.test"
  }.freeze

  # User-Agent aceito pelo allow_browser do ApplicationController.
  MODERN_BROWSER = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36".freeze

  def brand_channel(brand, channel)
    BrandChannel.where(brand: brand, channel: channel).order(:value).first!
  end

  # Lojista das seeds com as três identidades.
  def seed_contact(brand, index = 0)
    Tenancy.with_brand(brand) { Contact.order(:id).offset(index).first! }
  end

  def identity_of(contact, channel)
    Tenancy.with_brand(contact.brand_id) { ContactIdentity.find_by!(contact_id: contact.id, channel: channel).value }
  end

  def inbound_message(brand:, channel:, identity:, **attributes)
    brand_channel = channel.to_s == "chat" ? nil : brand_channel(brand, channel)
    Channels::InboundMessage.new(
      brand: brand, channel: channel, identity: identity, brand_channel: brand_channel,
      received_at: Time.current, text: "Meu repasse de ontem não caiu", external_id: SecureRandom.uuid, **attributes
    )
  end

  def audit_events_of(brand, conversation_id)
    Tenancy.with_brand(brand) { AuditEvent.where(conversation_id: conversation_id).order(:created_at, :id).to_a }
  end

  def webhook_jobs
    SolidQueue::Job.where(class_name: "Agents::WebhookDeliveryJob")
  end

  def jobs_of(job_class)
    SolidQueue::Job.where(class_name: job_class.name)
  end

  def job_arguments(job)
    job.arguments.fetch("arguments").first
  end

  # Webhook da Cloud API com as mensagens informadas, recebido pelo phone_number_id.
  def whatsapp_payload(phone_number_id:, messages:, contacts: [])
    {
      "object" => "whatsapp_business_account",
      "entry" => [ {
        "id" => "102290129340398",
        "changes" => [ {
          "field" => "messages",
          "value" => {
            "messaging_product" => "whatsapp",
            "metadata" => { "display_phone_number" => "15550783881", "phone_number_id" => phone_number_id },
            "contacts" => contacts,
            "messages" => messages
          }
        } ]
      } ]
    }
  end

  def whatsapp_text(from:, text:, id: "wamid.#{SecureRandom.hex(8)}")
    { "from" => from, "id" => id, "timestamp" => Time.current.to_i.to_s, "type" => "text", "text" => { "body" => text } }
  end
end

RSpec.configure do |config|
  config.include ChannelHelpers
  config.include ActiveSupport::Testing::TimeHelpers

  config.before(:suite) { ENV.update(ChannelHelpers::ENVIRONMENT) }
  config.after { Current.reset }
end

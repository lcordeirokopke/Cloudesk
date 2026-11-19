# Exporta para o simulador de canais os lojistas das seeds e os canais das marcas.
# O simulador lê o arquivo para escrever como um lojista conhecido, pelos números de WhatsApp e
# pelos e-mails de suporte de cada marca.
#
# Roda com o papel da aplicação. Os lojistas são lidos em Tenancy.with_brand, marca por marca;
# brand_channels fica fora do RLS. Só entram os lojistas com as três identidades (whatsapp, email
# e chat). A ordem é fixa (marca por slug, lojista por id, canais por value), e o arquivo não tem
# horário de geração: duas execuções no mesmo banco geram o mesmo arquivo.
#
# Destino: ENV["SIMULATOR_PERSONAS_PATH"], padrão tmp/simulator/personas.json.
module SimulatorPersonas
  DEFAULT_PATH = "tmp/simulator/personas.json".freeze
  CHANNELS = %w[whatsapp email chat].freeze

  module_function

  def path
    Rails.root.join(ENV.fetch("SIMULATOR_PERSONAS_PATH", DEFAULT_PATH))
  end

  def export(destination = path)
    destination = Pathname(destination)
    FileUtils.mkdir_p(destination.dirname)
    File.write(destination, "#{JSON.pretty_generate(build)}\n")
    destination
  end

  def build
    { "brands" => Brand.order(:slug).map { |brand| brand_entry(brand) } }
  end

  def brand_entry(brand)
    channels = BrandChannel.where(brand: brand).order(:value)

    {
      "slug" => brand.slug,
      "locale" => brand.locale,
      "whatsapp_numbers" => channels.where(channel: "whatsapp").map do |channel|
        { "phone_number_id" => channel.value, "display" => channel.display_value }
      end,
      "support_emails" => channels.where(channel: "email").map(&:value),
      "contacts" => Tenancy.with_brand(brand) { contacts }
    }
  end

  def contacts
    identities = ContactIdentity.where(channel: CHANNELS).order(:id)
                                .group_by(&:contact_id)
                                .transform_values { |list| list.to_h { |identity| [ identity.channel, identity.value ] } }

    Contact.order(:id).filter_map do |contact|
      values = identities.fetch(contact.id, {})
      next unless CHANNELS.all? { |channel| values.key?(channel) }

      { "name" => contact.name }.merge(CHANNELS.to_h { |channel| [ channel, values.fetch(channel) ] })
    end
  end
end

namespace :simulator do
  desc "Exporta lojistas das seeds e canais das marcas para o simulador de canais"
  task personas: :environment do
    destination = SimulatorPersonas.export
    puts "Personas gravadas em #{destination}"
  end
end

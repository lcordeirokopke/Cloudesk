require "rails_helper"
require "rake"

# Task simulator:personas: exporta lojistas das seeds e canais das marcas para o simulador.
RSpec.describe "simulator:personas" do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "simulator", "personas.json")
      previous = ENV["SIMULATOR_PERSONAS_PATH"]
      ENV["SIMULATOR_PERSONAS_PATH"] = @path
      example.run
    ensure
      ENV["SIMULATOR_PERSONAS_PATH"] = previous
    end
  end

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("simulator:personas")
  end

  def run_task
    task = Rake::Task["simulator:personas"]
    task.reenable
    expect { task.invoke }.to output(/Personas gravadas/).to_stdout
    File.read(@path)
  end

  def brand_entry(data, slug)
    data.fetch("brands").find { |brand| brand["slug"] == slug }
  end

  it "grava as duas marcas, com locale e os canais da marca" do
    data = JSON.parse(run_task)

    expect(data["brands"].map { |brand| brand["slug"] }).to eq(%w[infinitepay jim])
    expect(brand_entry(data, "infinitepay")).to include(
      "locale" => "pt-BR",
      "whatsapp_numbers" => [
        { "phone_number_id" => "110000000000001", "display" => "551140000001" },
        { "phone_number_id" => "110000000000002", "display" => "551140000002" }
      ],
      "support_emails" => %w[financeiro@infinitepay.test suporte@infinitepay.test]
    )
    expect(brand_entry(data, "jim")).to include(
      "locale" => "en-US",
      "whatsapp_numbers" => [
        { "phone_number_id" => "120000000000001", "display" => "15555550101" },
        { "phone_number_id" => "120000000000002", "display" => "15555550102" }
      ],
      "support_emails" => %w[payouts@jim.test support@jim.test]
    )
  end

  it "grava em cada marca só os lojistas da marca, com as três identidades e na ordem do id" do
    data = JSON.parse(run_task)

    [ infinitepay, jim ].each do |brand|
      expected = Tenancy.with_brand(brand) do
        Contact.order(:id).map do |contact|
          identities = ContactIdentity.where(contact_id: contact.id).pluck(:channel, :value).to_h
          { "name" => contact.name, "whatsapp" => identities["whatsapp"], "email" => identities["email"],
            "chat" => identities["chat"] }
        end
      end

      contacts = brand_entry(data, brand.slug).fetch("contacts")
      expect(contacts.size).to eq(50)
      expect(contacts).to eq(expected)
      expect(contacts).to all(include("name", "whatsapp", "email", "chat"))
    end
  end

  it "deixa de fora o lojista sem as três identidades" do
    Tenancy.with_brand(infinitepay) do
      contact = Contact.create!(name: "Lojista só WhatsApp", locale: "pt-BR")
      contact.identities.create!(channel: "whatsapp", value: "+5511900000000")
    end

    names = brand_entry(JSON.parse(run_task), "infinitepay")["contacts"].map { |contact| contact["name"] }

    expect(names).not_to include("Lojista só WhatsApp")
  end

  it "gera o mesmo arquivo em duas execuções" do
    expect(run_task).to eq(run_task)
  end
end

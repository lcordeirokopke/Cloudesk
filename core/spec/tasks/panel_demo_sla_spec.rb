require "rails_helper"
require "rake"

# Tasks panel:demo_sla e panel:demo_sla_reset: SLA de demonstração na regra genérica da marca.
RSpec.describe "panel:demo_sla" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("panel:demo_sla")
  end

  around do |example|
    previous = ENV.values_at("BRAND", "MINUTES")
    example.run
  ensure
    ENV["BRAND"], ENV["MINUTES"] = previous
  end

  def run_task(name, **env)
    env.each { |key, value| ENV[key.to_s] = value }
    task = Rake::Task[name]
    task.reenable
    expect { task.invoke }.to output.to_stdout
  end

  def generic_rule(brand)
    Tenancy.with_brand(brand) { RoutingRule.current.order(:position).find(&:generic?) }
  end

  it "publica uma nova versão da regra genérica com o SLA informado, só na marca" do
    before = generic_rule(infinitepay)
    jim_before = generic_rule(jim)

    run_task("panel:demo_sla", BRAND: "infinitepay", MINUTES: "1")

    after = generic_rule(infinitepay)
    expect(after).to have_attributes(rule_id: before.rule_id, version: before.version + 1, name: before.name)
    expect(after["then"]).to eq(before["then"].merge("sla_minutes" => 1))
    expect(generic_rule(jim).version).to eq(jim_before.version)
    published = Tenancy.with_brand(infinitepay) { AuditEvent.where(action: "routing_rule.published").order(:created_at).last }
    expect(published.payload.dig("payload", "diff")).to include("then")
  end

  it "o reset volta ao SLA da fila da regra genérica" do
    run_task("panel:demo_sla", BRAND: "infinitepay", MINUTES: "1")

    run_task("panel:demo_sla_reset", BRAND: "infinitepay")

    rule = generic_rule(infinitepay)
    queue_sla = Tenancy.with_brand(infinitepay) { Routing::Queue.find_by!(name: rule["then"]["queue"]).sla_minutes }
    expect(rule["then"]["sla_minutes"]).to eq(queue_sla)
  end

  it "a conversa roteada depois pela regra genérica recebe o SLA de demonstração" do
    run_task("panel:demo_sla", BRAND: "infinitepay", MINUTES: "1")
    contact = seed_contact_in_segment(infinitepay, "baixo_tpv")

    conversation = Conversations::Intake.call(
      inbound_message(brand: infinitepay, channel: "whatsapp", identity: identity_of(contact, "whatsapp"),
                      text: "Oi, tudo bem?")
    ).first.conversation

    expect(conversation).to have_attributes(state: "with_ai", sla_minutes: 1)
  end

  it "recusa marca desconhecida e minutos inválidos" do
    expect { PanelDemoSla.apply("inexistente", "1") }.to raise_error(ArgumentError, /marca/)
    expect { PanelDemoSla.apply("infinitepay", "0") }.to raise_error(ArgumentError, /MINUTES/)
    expect { PanelDemoSla.apply("infinitepay", "abc") }.to raise_error(ArgumentError, /MINUTES/)
  end
end

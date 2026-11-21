require "rails_helper"

RSpec.describe Admin::History do
  let(:brand) { infinitepay }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def queue(name, target = brand)
    in_brand(target) { Routing::Queue.find_by!(name: name) }
  end

  def edit_capacity(target, capacity, brand_for = brand)
    Admin::QueueEditor.update(brand: brand_for, queue_id: target.id, attributes: { capacity: capacity },
                              expected_updated_at: Admin::Editor.version_of(target), operator_name: "op")
  end

  it "devolve os eventos do registro em ordem" do
    target = queue("ip-maquininha")
    edit_capacity(target, 61)
    edit_capacity(queue("ip-maquininha"), 62)
    edit_capacity(queue("ip-suporte-geral"), 101)

    events = in_brand { described_class.for_record(target) }

    expect(events.map(&:action)).to eq(%w[queue.updated queue.updated])
    expect(events.map { |event| event.after["capacity"] }).to eq([ 61, 62 ])
  end

  it "devolve as versões de uma regra pelo rule_id" do
    rule = Routing::RulePublisher.create(
      brand: brand, attributes: { name: "Histórico", position: 40, when: { brand: "infinitepay", channel: "email" },
                                  then: { queue: "ip-financeiro", priority: 5 } }
    )
    Routing::RulePublisher.update(brand: brand, rule_id: rule.rule_id, attributes: { position: 41 })
    Routing::RulePublisher.create(
      brand: brand, attributes: { name: "Outra", position: 42, when: { brand: "infinitepay", channel: "chat" },
                                  then: { queue: "ip-financeiro", priority: 5 } }
    )

    events = in_brand { described_class.for_rule(rule.rule_id) }

    expect(events.map { |event| event.payload.dig("payload", "version") }).to eq([ 1, 2 ])
    expect(events.map { |event| event.payload.dig("payload", "operation") }).to eq(%w[create update])
  end

  it "eventos de outra marca não aparecem" do
    jim_queue = queue("jim-finance", jim)
    edit_capacity(jim_queue, 51, jim)

    expect(in_brand { described_class.for_record(jim_queue) }).to be_empty
    expect(in_brand(jim) { described_class.for_record(jim_queue) }.size).to eq(1)
  end
end

require "rails_helper"

RSpec.describe Admin::QueueEditor do
  let(:brand) { infinitepay }
  let(:operator) { "operator-a" }

  def in_brand(target = brand, &block)
    Tenancy.with_brand(target, &block)
  end

  def queue(name, target = brand)
    in_brand(target) { Routing::Queue.find_by!(name: name) }
  end

  def team(name)
    in_brand { Team.find_by!(name: name) }
  end

  def rule(name)
    in_brand { RoutingRule.latest_versions.find_by!(name: name) }
  end

  def edit(queue, attributes, expected: Admin::Editor.version_of(queue))
    described_class.update(brand: brand, queue_id: queue.id, attributes: attributes, expected_updated_at: expected,
                           operator_name: operator)
  end

  def create(attributes, target = brand)
    described_class.create(brand: target, attributes: attributes, operator_name: operator)
  end

  def events(record, action)
    in_brand { AuditEvent.where(target_type: "Routing::Queue", target_id: record.id, action: action).order(:created_at).to_a }
  end

  def new_queue(name, **attributes)
    create({ name: name, team_id: team("Suporte Técnico").id, sla_minutes: 30, capacity: 10, first_attendant: "ai" }.merge(attributes))
  end

  let(:attributes) do
    { name: "ip-nova", team_id: team("Financeiro").id, sla_minutes: 30, capacity: 10, first_attendant: "human" }
  end

  describe "create" do
    it "grava a fila na marca do bloco com queue.created, ator operator, after e diff" do
      created = create(attributes)

      expect(created).to have_attributes(name: "ip-nova", brand_id: brand.id, sla_minutes: 30, first_attendant: "human")
      event = events(created, "queue.created").sole
      expect(event).to have_attributes(actor_type: "operator", actor_id: nil, before: nil)
      expect(event.after).to include("name" => "ip-nova", "capacity" => 10, "team_id" => team("Financeiro").id)
      payload = event.payload.fetch("payload")
      expect(payload).to include("operation" => "create", "operator_name" => "operator-a")
      expect(payload["diff"]["name"]).to eq("before" => nil, "after" => "ip-nova")
      expect(payload["diff"].keys).to include("sla_minutes", "capacity", "first_attendant", "team_id")
      expect(event.payload["brand"]).to eq("infinitepay")
    end

    it "recusa as validações do model com as mensagens" do
      expect { create(attributes.merge(sla_minutes: 0, first_attendant: "robo")) }
        .to raise_error(Admin::Invalid) { |error| expect(error.messages.size).to be >= 2 }
    end

    it "recusa nome repetido na marca sem exceção do índice único; o mesmo nome em outra marca passa" do
      expect { create(attributes.merge(name: "ip-financeiro")) }
        .to raise_error(Admin::Invalid, /já existe fila com o nome ip-financeiro/)

      jim_team = in_brand(jim) { Team.find_by!(name: "Finance") }
      created = create(attributes.merge(name: "ip-financeiro", team_id: jim_team.id), jim)
      expect(created.brand_id).to eq(jim.id)
    end

    it "recusa equipe de outra marca" do
      jim_team = in_brand(jim) { Team.find_by!(name: "Finance") }

      expect { create(attributes.merge(team_id: jim_team.id)) }.to raise_error(Admin::Invalid, /equipe não existe/)
    end
  end

  describe "update" do
    it "grava queue.updated com before, after e diff só dos atributos que mudam" do
      target = queue("ip-maquininha")

      updated = edit(target, { capacity: 70, sla_minutes: 40 })

      expect(updated).to have_attributes(capacity: 70, sla_minutes: 40)
      event = events(target, "queue.updated").sole
      expect(event).to have_attributes(actor_type: "operator", actor_id: nil)
      expect(event.before).to include("capacity" => 60, "sla_minutes" => 45)
      expect(event.after).to include("capacity" => 70, "sla_minutes" => 40)
      expect(event.payload.dig("payload", "diff")).to eq(
        "capacity" => { "before" => 60, "after" => 70 }, "sla_minutes" => { "before" => 45, "after" => 40 }
      )
      expect(event.payload.dig("payload", "operation")).to eq("update")
      expect(event.payload.dig("payload", "operator_name")).to eq("operator-a")
    end

    it "edição sem mudança levanta Unchanged" do
      target = queue("ip-maquininha")

      expect { edit(target, { capacity: 60 }) }.to raise_error(Admin::Unchanged)
      expect(events(target, "queue.updated")).to be_empty
    end

    it "updated_at diferente do lido levanta Stale e nada é gravado" do
      target = queue("ip-maquininha")
      stale = Admin::Editor.version_of(target)
      edit(target, { capacity: 70 })

      expect { edit(target, { capacity: 80 }, expected: stale) }.to raise_error(Admin::Stale)
      expect(queue("ip-maquininha").capacity).to eq(70)
      expect(events(target, "queue.updated").size).to eq(1)
    end

    it "atributo desconhecido levanta ArgumentError" do
      expect { edit(queue("ip-maquininha"), { brand_id: jim.id }) }.to raise_error(ArgumentError, /brand_id/)
    end

    it "fila de outra marca não existe" do
      expect { edit(queue("jim-finance", jim), { capacity: 70 }) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "erro depois do save! desfaz a mudança e não grava evento" do
      target = queue("ip-maquininha")
      allow(AuditEvent).to receive(:create!).and_raise(RuntimeError, "falha forçada")

      expect { edit(target, { capacity: 70 }) }.to raise_error(RuntimeError, "falha forçada")
      expect(queue("ip-maquininha").capacity).to eq(60)
      expect(events(target, "queue.updated")).to be_empty
    end
  end

  describe "renomear fila citada por regra" do
    it "recusa quando a maior versão de uma regra ativa cita a fila, com o nome da regra" do
      target = queue("ip-suporte-geral")

      expect { edit(target, { name: "ip-suporte" }) }
        .to raise_error(Admin::Invalid, /InfinitePay · Geral/)
      expect(queue("ip-suporte-geral")).to be_present
      expect(events(target, "queue.updated")).to be_empty
    end

    it "recusa também quando só uma regra inativa cita a fila" do
      target = new_queue("ip-temporaria")
      cited = Routing::RulePublisher.create(
        brand: brand, attributes: { name: "Temporária", position: 50, when: { brand: "infinitepay", channel: "email" },
                                    then: { queue: "ip-temporaria", priority: 5 } }
      )
      Routing::RulePublisher.deactivate(brand: brand, rule_id: cited.rule_id)

      expect { edit(queue("ip-temporaria"), { name: "ip-temporaria-2" }) }.to raise_error(Admin::Invalid, /Temporária/)
      expect(events(target, "queue.updated")).to be_empty
    end

    it "passa depois que as regras mudam de fila; versões antigas não bloqueiam" do
      new_queue("ip-temporaria")
      cited = Routing::RulePublisher.create(
        brand: brand, attributes: { name: "Temporária", position: 50, when: { brand: "infinitepay", channel: "email" },
                                    then: { queue: "ip-temporaria", priority: 5 } }
      )
      Routing::RulePublisher.update(brand: brand, rule_id: cited.rule_id,
                                    attributes: { then: { queue: "ip-suporte-geral", priority: 5 } })

      renamed = edit(queue("ip-temporaria"), { name: "ip-temporaria-2" })

      expect(renamed.name).to eq("ip-temporaria-2")
      in_brand do
        expect(RoutingRule.find_by!(rule_id: cited.rule_id, version: 1)["then"]["queue"]).to eq("ip-temporaria")
      end
    end
  end

  describe "renomeação e publicação de regra simultâneas" do
    self.use_transactional_tests = false

    let(:owner) { OwnerRecord.lease_connection }

    after do
      ids = in_brand { RoutingRule.where(name: "Corrida").pluck(:id) }
      queue_ids = in_brand { Routing::Queue.where(name: %w[ip-corrida ip-corrida-2]).pluck(:id) }
      OwnerRecord.transaction do
        owner.execute("SELECT set_config('app.brand_id', #{owner.quote(brand.id)}, true)")
        owner.execute("ALTER TABLE audit_events DISABLE TRIGGER audit_events_block_row_changes")
        targets = (ids + queue_ids).map { |id| owner.quote(id) }
        owner.execute("DELETE FROM audit_events WHERE target_id IN (#{targets.join(', ')})") if targets.any?
        owner.execute("ALTER TABLE audit_events ENABLE TRIGGER audit_events_block_row_changes")
        owner.execute("DELETE FROM routing_rules WHERE id IN (#{ids.map { |id| owner.quote(id) }.join(', ')})") if ids.any?
        owner.execute("DELETE FROM queues WHERE id IN (#{queue_ids.map { |id| owner.quote(id) }.join(', ')})") if queue_ids.any?
      end
    end

    it "termina com a regra citando uma fila existente: uma das duas operações é recusada" do
      target = new_queue("ip-corrida")
      expected = Admin::Editor.version_of(target)
      start = Queue.new
      results = {}

      threads = [
        Thread.new do
          start.pop
          ApplicationRecord.connection_pool.with_connection do
            Routing::RulePublisher.create(
              brand: brand, attributes: { name: "Corrida", position: 60, when: { brand: "infinitepay", channel: "email" },
                                          then: { queue: "ip-corrida", priority: 5 } }
            )
            results[:rule] = :ok
          rescue Routing::RuleDefinition::Invalid
            results[:rule] = :refused
          end
        end,
        Thread.new do
          start.pop
          ApplicationRecord.connection_pool.with_connection do
            described_class.update(brand: brand, queue_id: target.id, attributes: { name: "ip-corrida-2" },
                                   expected_updated_at: expected, operator_name: operator)
            results[:rename] = :ok
          rescue Admin::Invalid
            results[:rename] = :refused
          end
        end
      ]
      2.times { start << true }
      threads.each(&:join)

      expect(results.values).to contain_exactly(:ok, :refused)
      in_brand do
        names = Routing::Queue.pluck(:name)
        RoutingRule.latest_versions.each { |version| expect(names).to include(version["then"]["queue"]) }
      end
    end
  end

  describe "fila de escalação" do
    it "recusa first_attendant ai na fila que é escalation_queue de outra" do
      expect { edit(queue("ip-financeiro"), { first_attendant: "ai" }) }
        .to raise_error(Admin::Invalid, /ip-financeiro-prioritaria/)
    end

    it "aceita first_attendant ai na fila que não é escalation_queue" do
      expect(edit(queue("ip-urgente"), { first_attendant: "ai" }).first_attendant).to eq("ai")
    end

    it "recusa escalation_queue que não é humana (validação do model)" do
      expect { edit(queue("ip-maquininha"), { escalation_queue_id: queue("ip-suporte-geral").id }) }
        .to raise_error(Admin::Invalid, /humana/)
    end
  end

  describe "equipe da fila de destino de regra com hours" do
    # ip-maquininha é destino de "InfinitePay · Maquininha" (when.hours business), ativa nas seeds.
    let(:target) { queue("ip-maquininha") }

    it "recusa equipe sem horário, com horário inválido ou nenhuma equipe" do
      without = Admin::TeamEditor.create(brand: brand, attributes: { name: "Sem horário", business_hours: {} },
                                         operator_name: operator)
      invalid = in_brand { Team.create!(name: "Horário inválido", business_hours: { "weekdays" => [ 9 ] }) }

      [ without.id, invalid.id, nil ].each do |team_id|
        expect { edit(target, { team_id: team_id }) }.to raise_error(Admin::Invalid, /InfinitePay · Maquininha/)
      end
      expect(events(target, "queue.updated")).to be_empty
    end

    it "aceita equipe com horário válido, com queue.updated e o diff de team_id" do
      updated = edit(target, { team_id: team("Financeiro").id })

      expect(updated.team_id).to eq(team("Financeiro").id)
      expect(events(target, "queue.updated").sole.payload.dig("payload", "diff")).to eq(
        "team_id" => { "before" => team("Suporte Técnico").id, "after" => team("Financeiro").id }
      )
    end

    it "fila sem regra hours troca para equipe sem horário" do
      without = Admin::TeamEditor.create(brand: brand, attributes: { name: "Sem horário", business_hours: {} },
                                         operator_name: operator)

      expect(edit(queue("ip-suporte-geral"), { team_id: without.id }).team_id).to eq(without.id)
    end
  end

  describe "ciclo de transbordo" do
    it "o admin cria A → B → A e o Routing::Route termina na última fila visitada, com a cadeia no evento" do
      first = new_queue("ip-ciclo-a", capacity: 1)
      second = new_queue("ip-ciclo-b", capacity: 1, overflow_queue_id: first.id)
      edit(first, { overflow_queue_id: second.id })
      Routing::RulePublisher.create(
        brand: brand, attributes: { name: "Ciclo", position: 0, when: { brand: "infinitepay" },
                                    then: { queue: "ip-ciclo-a", priority: 1 } }
      )

      conversation = in_brand do
        contacts = Contact.order(:id).limit(3).to_a
        [ first, second ].each_with_index do |occupied, index|
          Conversation.create!(contact: contacts[index], channel: "chat").update!(queue_id: occupied.id, state: "with_ai")
        end
        fresh = Conversation.create!(contact: contacts[2], channel: "chat")
        Routing::Route.call(conversation: fresh, trigger: "intake", text: "oi").conversation
      end

      expect(conversation.queue_id).to eq(second.id)
      routed = in_brand { AuditEvent.where(conversation_id: conversation.id, action: "conversation.routed").sole }
      expect(routed.payload.dig("payload", "queue_chain").map { |step| step["queue"] }).to eq(%w[ip-ciclo-a ip-ciclo-b])
      expect(routed.payload.dig("payload", "overflow")).to be(true)
    end
  end
end

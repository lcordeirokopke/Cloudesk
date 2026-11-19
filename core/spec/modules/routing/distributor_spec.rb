require "rails_helper"

RSpec.describe Routing::Distributor do
  let(:brand) { infinitepay }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def analysts(team_name)
    in_brand { Attendant.where(kind: "human", team: Team.find_by!(name: team_name)).order(:name).to_a }
  end

  # Conversa na fila humana, de um lojista das seeds.
  def waiting(contact_index, queue_name, priority:, queued_at:)
    in_brand do
      conversation = Conversation.create!(contact: seed_contact(brand, contact_index), channel: "whatsapp")
      conversation.update!(queue: Routing::Queue.find_by!(name: queue_name), priority: priority, queued_at: queued_at,
                           state: "awaiting_human")
      conversation
    end
  end

  let(:analyst) { analysts("Financeiro").first }

  it "atribui a conversa de maior prioridade e, no empate, a há mais tempo na fila" do
    low = waiting(0, "ip-financeiro", priority: 10, queued_at: 3.hours.ago)
    newer = waiting(1, "ip-financeiro", priority: 50, queued_at: 1.minute.ago)
    older = waiting(2, "ip-financeiro", priority: 50, queued_at: 1.hour.ago)

    expect(described_class.next_for(analyst).id).to eq(older.id)
    expect(described_class.next_for(analyst).id).to eq(newer.id)
    expect(described_class.next_for(analyst).id).to eq(low.id)
    expect(described_class.next_for(analyst)).to be_nil
  end

  it "passa a conversa para with_human com o analista e grava conversation.assigned" do
    conversation = waiting(0, "ip-financeiro", priority: 50, queued_at: 5.minutes.ago)

    assigned = described_class.next_for(analyst)

    expect(assigned).to have_attributes(id: conversation.id, state: "with_human", attendant_id: analyst.id)
    event = audit_events_of(brand, conversation.id).last
    expect(event).to have_attributes(action: "conversation.assigned", actor_type: "analyst", actor_id: analyst.id,
                                     before: { "state" => "awaiting_human", "attendant_id" => nil },
                                     after: { "state" => "with_human", "attendant_id" => analyst.id })
    expect(event.payload.dig("payload", "priority")).to eq(50)
  end

  it "puxa só das filas da equipe do analista" do
    waiting(0, "ip-suporte-geral", priority: 99, queued_at: 1.hour.ago)
    finance = waiting(1, "ip-financeiro-prioritaria", priority: 1, queued_at: 1.minute.ago)

    expect(described_class.next_for(analyst).id).to eq(finance.id)
    expect(described_class.next_for(analyst)).to be_nil
    expect(described_class.next_for(analysts("Suporte Técnico").first)).to be_present
  end

  it "na capacidade, o analista não recebe caso" do
    in_brand { Attendant.find(analyst.id).update!(capacity: 1) }
    waiting(0, "ip-financeiro", priority: 50, queued_at: 1.hour.ago)
    second = waiting(1, "ip-financeiro", priority: 50, queued_at: 1.minute.ago)

    expect(described_class.next_for(analyst)).to be_present
    expect(described_class.next_for(analyst)).to be_nil
    in_brand { expect(Conversation.find(second.id).state).to eq("awaiting_human") }
  end

  it "só analista humano com equipe recebe caso" do
    ai = in_brand { Attendant.find_by!(kind: "ai") }

    expect { described_class.next_for(ai) }.to raise_error(ArgumentError)
  end

  # Cada thread usa uma conexão e uma transação próprias, com commit de verdade; por isso os
  # exemplos rodam fora da transação do RSpec e apagam o que gravam.
  describe "com analistas concorrentes" do
    self.use_transactional_tests = false

    let(:conversation_ids) { [] }

    after do
      purge_conversations(brand, conversation_ids)
      in_brand { Attendant.find(analyst.id).update!(capacity: 5) }
    end

    # Conversas de lojistas do fim da lista das seeds, para não colidir com outros exemplos.
    def commit_waiting(count)
      count.times do |index|
        conversation_ids << waiting(40 + index, "ip-financeiro", priority: 50, queued_at: (count - index).minutes.ago).id
      end
    end

    # Cada analista puxa casos em uma transação que fica aberta até todos terminarem: as conversas
    # atribuídas ficam travadas enquanto os outros procuram.
    def pull_concurrently(pullers, pulls_per_analyst)
      ready = Thread::Queue.new
      start = Thread::Queue.new
      done = Concurrent::CountDownLatch.new(pullers.size)

      threads = pullers.map do |puller|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            in_brand do
              ready << true
              start.pop
              assigned = pulls_per_analyst.times.map { described_class.next_for(puller)&.id }
              done.count_down
              done.wait(5)
              sleep 0.2
              assigned
            end
          end
        end
      end

      pullers.size.times { ready.pop }
      pullers.size.times { start << :go }
      threads.map(&:value)
    end

    it "dois analistas nunca recebem o mesmo caso" do
      commit_waiting(3)
      first, second = analysts("Financeiro")

      assigned = pull_concurrently([ first, second ], 2).flatten

      expect(assigned.compact).to match_array(conversation_ids)
      expect(assigned.count(nil)).to eq(1)
      in_brand do
        expect(Conversation.where(id: conversation_ids).pluck(:state).uniq).to eq([ "with_human" ])
        expect(AuditEvent.where(action: "conversation.assigned", conversation_id: conversation_ids).count).to eq(3)
      end
    end

    it "pedidos simultâneos do mesmo analista respeitam a capacidade" do
      in_brand { Attendant.find(analyst.id).update!(capacity: 1) }
      commit_waiting(2)

      threads = 2.times.map do
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            in_brand do
              id = described_class.next_for(analyst)&.id
              sleep 0.2
              id
            end
          end
        end
      end
      assigned = threads.map(&:value)

      expect(assigned.compact.size).to eq(1)
      in_brand { expect(Conversation.where(id: conversation_ids, state: "with_human").count).to eq(1) }
    end
  end
end

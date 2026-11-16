require "rails_helper"

RSpec.describe "Sequência de mensagens por conversa" do
  def message_attributes(body)
    { channel: "whatsapp", author: "customer", body: body }
  end

  it "numera as mensagens a partir de 1, na ordem de gravação" do
    Tenancy.with_brand(infinitepay) do
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")

      sequences = 3.times.map { |index| conversation.append_message!(message_attributes("msg #{index}")).sequence }

      expect(sequences).to eq([ 1, 2, 3 ])
      expect(conversation.last_sequence).to eq(3)
      expect(conversation.reload.last_sequence).to eq(3)
    end
  end

  it "desfaz o incremento quando a mensagem não é gravada" do
    Tenancy.with_brand(infinitepay) do
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")

      expect { conversation.append_message!(message_attributes("")) }.to raise_error(ActiveRecord::RecordInvalid)

      expect(conversation.reload.last_sequence).to eq(0)
      expect(conversation.append_message!(message_attributes("oi")).sequence).to eq(1)
    end
  end

  it "o índice único recusa a sequência repetida na mesma conversa" do
    Tenancy.with_brand(infinitepay) do
      conversation = Conversation.create!(contact: Contact.first!, channel: "whatsapp")
      message = conversation.append_message!(message_attributes("oi"))

      expect do
        in_savepoint { conversation.messages.create!(message_attributes("de novo").merge(sequence: message.sequence)) }
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # Cada thread usa uma conexão e uma transação próprias, com commit de verdade; por isso o exemplo
  # roda fora da transação do RSpec e apaga o que grava.
  describe "com escritas concorrentes" do
    self.use_transactional_tests = false

    let(:brand) { infinitepay }
    let(:conversation_id) do
      Tenancy.with_brand(brand) { Conversation.create!(contact: Contact.first!, channel: "whatsapp").id }
    end

    after do
      Tenancy.with_brand(brand) do
        Message.where(conversation_id: conversation_id).delete_all
        Conversation.where(id: conversation_id).delete_all
      end
    end

    it "duas mensagens na mesma conversa recebem sequências distintas e consecutivas" do
      conversation_id
      ready = Thread::Queue.new
      start = Thread::Queue.new

      threads = 2.times.map do |index|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            Tenancy.with_brand(brand) do
              conversation = Conversation.find(conversation_id)
              ready << index
              start.pop
              message = conversation.append_message!(message_attributes("concorrente #{index}"))
              # Mantém a transação aberta: a outra thread espera no bloqueio da linha da conversa.
              sleep 0.3
              message.sequence
            end
          end
        end
      end

      2.times { ready.pop }
      2.times { start << :go }
      sequences = threads.map(&:value)

      expect(sequences.sort).to eq([ 1, 2 ])
      Tenancy.with_brand(brand) do
        expect(Message.where(conversation_id: conversation_id).order(:sequence).pluck(:sequence)).to eq([ 1, 2 ])
        expect(Conversation.find(conversation_id).last_sequence).to eq(2)
      end
    end
  end
end

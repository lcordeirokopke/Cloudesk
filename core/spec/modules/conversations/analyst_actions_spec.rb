require "rails_helper"

RSpec.describe Conversations::AnalystActions do
  let(:brand) { infinitepay }
  let(:contact) { seed_contact_in_segment(brand, "medio_tpv") }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  def analysts
    in_brand { Attendant.where(kind: "human", team: Team.find_by!(name: "Financeiro")).order(:name).to_a }
  end

  let(:analyst) { analysts.first }
  let(:other_analyst) { analysts.second }

  # Repasse de lojista medio_tpv: fila humana ip-financeiro. O e-mail entra depois do WhatsApp, e a
  # resposta sai pelo canal da última mensagem do lojista.
  def conversation_with(analyst)
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "whatsapp", identity: identity_of(contact, "whatsapp"))
    )
    Conversations::Intake.call(
      inbound_message(brand: brand, channel: "email", identity: identity_of(contact, "email"), text: "Alguma novidade?")
    ).first
    Routing::Distributor.next_for(analyst)
  end

  def escalated_conversation_with(analyst)
    conversation = conversation_with(analyst)
    in_brand { Handoff.create!(conversation_id: conversation.id, reason: "pedido", summary: "Lojista pede analista", created_at: 1.minute.ago) }
    conversation
  end

  def reload(conversation)
    in_brand { Conversation.find(conversation.id) }
  end

  def events(conversation, action)
    audit_events_of(brand, conversation.id).select { |event| event.action == action }
  end

  describe ".reply!" do
    it "responde pelo canal da última mensagem do lojista, com o analista como atendente" do
      conversation = conversation_with(analyst)

      message = described_class.reply!(analyst: analyst, conversation_id: conversation.id, text: "Vou verificar.")

      expect(message).to have_attributes(author: "analyst", attendant_id: analyst.id, channel: "email",
                                         body: "Vou verificar.", sequence: 3)
      event = events(conversation, "message.created").last
      expect(event).to have_attributes(actor_type: "analyst", actor_id: analyst.id)
      expect(event.payload.dig("payload", "in_reply_to_sequence")).to eq(2)
      expect(jobs_of(Channels::DeliveryJob).map { |job| job_arguments(job)["message_id"] }).to include(message.id)
    end

    it "recusa o analista que não atende a conversa" do
      conversation = conversation_with(analyst)

      expect { described_class.reply!(analyst: other_analyst, conversation_id: conversation.id, text: "Oi") }
        .to raise_error(described_class::NotAllowed)
    end

    it "recusa a conversa fora de with_human" do
      conversation = conversation_with(analyst)
      described_class.resolve!(analyst: analyst, conversation_id: conversation.id)

      expect { described_class.reply!(analyst: analyst, conversation_id: conversation.id, text: "Oi") }
        .to raise_error(described_class::NotAllowed)
    end

    it "recusa mensagem vazia" do
      conversation = conversation_with(analyst)

      expect { described_class.reply!(analyst: analyst, conversation_id: conversation.id, text: "  ") }
        .to raise_error(described_class::NotAllowed)
    end

    it "não encontra conversa de outra marca" do
      conversation = conversation_with(analyst)
      jim_analyst = Tenancy.with_brand(jim) { Attendant.where(kind: "human").where.not(team_id: nil).first }

      expect { described_class.reply!(analyst: jim_analyst, conversation_id: conversation.id, text: "Oi") }
        .to raise_error(described_class::NotAllowed, /não encontrada/)
    end
  end

  describe ".resolve!" do
    it "leva a conversa a resolved, mantém o analista e grava conversation.resolved com o painel" do
      conversation = conversation_with(analyst)
      before_jobs = jobs_of(Conversations::PanelBroadcastJob).count

      described_class.resolve!(analyst: analyst, conversation_id: conversation.id)

      updated = reload(conversation)
      expect(updated).to have_attributes(state: "resolved", attendant_id: analyst.id)
      expect(updated.resolved_at).to be_present
      event = events(conversation, "conversation.resolved").sole
      expect(event).to have_attributes(actor_type: "analyst", actor_id: analyst.id)
      expect(event.before).to include("state" => "with_human")
      expect(event.after).to include("state" => "resolved")
      expect(jobs_of(Conversations::PanelBroadcastJob).count).to eq(before_jobs + 1)
      in_brand { expect(Message.where(conversation_id: conversation.id).pluck(:author)).to eq(%w[customer customer]) }
    end

    it "recusa o analista que não atende a conversa" do
      conversation = conversation_with(analyst)

      expect { described_class.resolve!(analyst: other_analyst, conversation_id: conversation.id) }
        .to raise_error(described_class::NotAllowed)
      expect(reload(conversation).state).to eq("with_human")
      expect(jobs_of(Conversations::MemoryRefreshJob)).to be_empty
    end

    it "enfileira o recálculo da memória do lojista" do
      conversation = conversation_with(analyst)

      described_class.resolve!(analyst: analyst, conversation_id: conversation.id)

      expect(jobs_of(Conversations::MemoryRefreshJob).map { |job| job_arguments(job) }).to contain_exactly(
        include("brand_id" => brand.id, "contact_id" => contact.id, "conversation_id" => conversation.id)
      )
    end
  end

  describe ".rate_handoff!" do
    it "grava a avaliação uma vez, com handoff.rated e o tempo até a primeira resposta humana" do
      conversation = escalated_conversation_with(analyst)
      handoff = in_brand { Handoff.find_by!(conversation_id: conversation.id) }
      described_class.reply!(analyst: analyst, conversation_id: conversation.id, text: "Vou verificar.")

      described_class.rate_handoff!(analyst: analyst, handoff_id: handoff.id, rating: "useful")

      rated = in_brand { Handoff.find(handoff.id) }
      expect(rated).to have_attributes(rating: "useful", rated_by_id: analyst.id)
      expect(rated.rated_at).to be_present
      event = events(conversation, "handoff.rated").sole
      expect(event).to have_attributes(actor_type: "analyst", actor_id: analyst.id, target_type: "Handoff", target_id: handoff.id)
      expect(event.payload.fetch("payload")).to include("handoff_id" => handoff.id, "rating" => "useful")
      expect(event.payload.dig("payload", "first_human_response_seconds")).to be_within(5).of(60)

      expect { described_class.rate_handoff!(analyst: analyst, handoff_id: handoff.id, rating: "not_useful") }
        .to raise_error(described_class::NotAllowed, /já foi avaliado/)
    end

    it "sem resposta humana, o tempo até a primeira resposta é nulo" do
      conversation = escalated_conversation_with(analyst)
      handoff = in_brand { Handoff.find_by!(conversation_id: conversation.id) }

      described_class.rate_handoff!(analyst: analyst, handoff_id: handoff.id, rating: "not_useful")

      expect(events(conversation, "handoff.rated").sole.payload.dig("payload", "first_human_response_seconds")).to be_nil
    end

    it "aceita a conversa resolvida pelo analista" do
      conversation = escalated_conversation_with(analyst)
      handoff = in_brand { Handoff.find_by!(conversation_id: conversation.id) }
      described_class.resolve!(analyst: analyst, conversation_id: conversation.id)

      described_class.rate_handoff!(analyst: analyst, handoff_id: handoff.id, rating: "useful")

      expect(in_brand { Handoff.find(handoff.id).rating }).to eq("useful")
    end

    it "recusa o analista que não atende a conversa e a avaliação inválida" do
      conversation = escalated_conversation_with(analyst)
      handoff = in_brand { Handoff.find_by!(conversation_id: conversation.id) }

      expect { described_class.rate_handoff!(analyst: other_analyst, handoff_id: handoff.id, rating: "useful") }
        .to raise_error(described_class::NotAllowed)
      expect { described_class.rate_handoff!(analyst: analyst, handoff_id: handoff.id, rating: "otimo") }
        .to raise_error(described_class::NotAllowed)
      expect(in_brand { Handoff.find(handoff.id).rating }).to be_nil
    end
  end
end

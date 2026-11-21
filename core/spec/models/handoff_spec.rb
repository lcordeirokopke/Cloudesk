require "rails_helper"

RSpec.describe Handoff do
  let(:brand) { infinitepay }

  def in_brand(&block)
    Tenancy.with_brand(brand, &block)
  end

  let(:analyst) { in_brand { Attendant.where(kind: "human").order(:name).first } }
  let(:conversation) { in_brand { Conversation.create!(contact: seed_contact(brand), channel: "whatsapp") } }

  def handoff(created_at: Time.current, **attributes)
    in_brand do
      Handoff.create!(conversation: conversation, reason: "pedido", summary: "Lojista pede analista",
                      created_at: created_at, **attributes)
    end
  end

  def message(author, created_at)
    in_brand do
      Conversation.find(conversation.id).append_message!(channel: "whatsapp", author: author, body: "texto",
                                                          attendant_id: author == "analyst" ? analyst.id : nil,
                                                          created_at: created_at)
    end
  end

  describe "#first_human_response_at" do
    it "é o horário da primeira mensagem de analista a partir do handoff" do
      record = handoff(created_at: 10.minutes.ago)
      message("analyst", 20.minutes.ago)
      message("customer", 8.minutes.ago)
      first = message("analyst", 5.minutes.ago)
      message("analyst", 2.minutes.ago)

      expect(in_brand { record.first_human_response_at }).to be_within(0.001).of(first.created_at)
    end

    it "é nil sem resposta de analista" do
      record = handoff
      message("customer", Time.current)

      expect(in_brand { record.first_human_response_at }).to be_nil
    end
  end

  describe "avaliação" do
    it "aceita useful e not_useful com analista e horário" do
      Handoff::RATINGS.each do |rating|
        expect(handoff(rating: rating, rated_by: analyst, rated_at: Time.current)).to be_persisted
      end
    end

    it "recusa outro valor" do
      record = in_brand { Handoff.new(conversation: conversation, reason: "r", summary: "s", rating: "otimo") }

      expect(record).not_to be_valid
      expect(record.errors[:rating]).to be_present
    end

    it "exige analista e horário com a avaliação" do
      record = in_brand { Handoff.new(conversation: conversation, reason: "r", summary: "s", rating: "useful") }

      expect(record).not_to be_valid
      expect(record.errors.attribute_names).to include(:rated_by, :rated_at)
    end

    it "o banco recusa avaliação fora da lista" do
      record = handoff
      expect_database_error(/handoffs_rating_check/) do
        in_brand { Handoff.where(id: record.id).update_all(rating: "otimo") }
      end
    end
  end
end

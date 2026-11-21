module Conversations
  # Ações do analista no painel. Cada uma roda em um Tenancy.with_brand da marca do analista, com a
  # conversa travada (FOR UPDATE), e grava os eventos com ator analyst:
  #   reply!:        com a conversa em with_human e atribuída ao analista, responde à última
  #                  mensagem do lojista pelo canal dela (Conversations::Outbound);
  #   resolve!:      mesmas exigências; with_human -> resolved (conversation.resolved), com
  #                  resolved_at, mantém o atendente e não envia mensagem ao lojista; enfileira o
  #                  recálculo da memória do lojista (Conversations::MemoryRefreshJob) na mesma
  #                  transação;
  #   rate_handoff!: o analista atribuído à conversa (with_human ou resolved) avalia o briefing do
  #                  handoff uma vez (handoff.rated), com o tempo até a primeira resposta humana.
  # Fora das exigências, levanta NotAllowed e nada é gravado.
  module AnalystActions
    class NotAllowed < StandardError; end

    RATEABLE_STATES = %w[with_human resolved].freeze

    module_function

    # Devolve a Message gravada.
    def reply!(analyst:, conversation_id:, text:)
      text = text.to_s.strip
      raise NotAllowed, "mensagem vazia" if text.empty?

      within(analyst, conversation_id) do |attendant, conversation, _brand|
        ensure_attending!(attendant, conversation)
        last_customer = Message.where(conversation_id: conversation.id, author: "customer").maximum(:sequence)
        raise NotAllowed, "a conversa não tem mensagem do lojista" if last_customer.nil?

        Outbound.append!(conversation: conversation, author: "analyst", text: text,
                         in_reply_to_sequence: last_customer, attendant: attendant)
      end
    end

    # Devolve a Conversation.
    def resolve!(analyst:, conversation_id:)
      within(analyst, conversation_id) do |attendant, conversation, brand|
        ensure_attending!(attendant, conversation)

        Audit::Command.call(brand: brand, type: "conversation.resolved", actor_type: "analyst", actor_id: attendant.id,
                            panel: true) do |change|
          change.before = snapshot(conversation)
          conversation.update!(state: "resolved", resolved_at: Current.received_at || Time.current)
          MemoryRefreshJob.perform_later(brand_id: brand.id, contact_id: conversation.contact_id,
                                         conversation_id: conversation.id)
          change.after = snapshot(conversation)
          change.target = conversation
          change.conversation = conversation
          conversation
        end.value
      end
    end

    # rating: useful ou not_useful. Devolve o Handoff.
    def rate_handoff!(analyst:, handoff_id:, rating:)
      raise NotAllowed, "avaliação inválida" unless Handoff::RATINGS.include?(rating.to_s)

      brand = Brand.find(analyst.brand_id)
      Tenancy.with_brand(brand) do
        conversation_id = Handoff.where(id: handoff_id).pick(:conversation_id)
        raise NotAllowed, "handoff não encontrado" if conversation_id.nil?

        conversation = Conversation.lock.find(conversation_id)
        handoff = Handoff.lock.find(handoff_id)
        attendant = human(analyst)
        unless conversation.attendant_id == attendant.id && RATEABLE_STATES.include?(conversation.state)
          raise NotAllowed, "só o analista da conversa avalia o briefing"
        end
        raise NotAllowed, "o briefing já foi avaliado" if handoff.rating

        rate(brand, attendant, conversation, handoff, rating.to_s)
      end
    end

    def rate(brand, attendant, conversation, handoff, rating)
      Audit::Command.call(brand: brand, type: "handoff.rated", actor_type: "analyst", actor_id: attendant.id,
                          panel: true) do |change|
        rated_at = Current.received_at || Time.current
        handoff.update!(rating: rating, rated_by: attendant, rated_at: rated_at)
        first_response = handoff.first_human_response_at
        change.target = handoff
        change.conversation = conversation
        change.after = { rating: rating, rated_by_id: attendant.id, rated_at: rated_at.utc.iso8601(3) }
        change.payload = {
          handoff_id: handoff.id, rating: rating,
          first_human_response_seconds: first_response && (first_response - handoff.created_at).round(3)
        }
        handoff
      end.value
    end

    def within(analyst, conversation_id)
      brand = Brand.find(analyst.brand_id)
      Tenancy.with_brand(brand) do
        conversation = Conversation.lock.find_by(id: conversation_id)
        raise NotAllowed, "conversa não encontrada" if conversation.nil?

        yield human(analyst), conversation, brand
      end
    end

    def human(analyst)
      attendant = Attendant.find_by(id: analyst.id, kind: "human")
      raise NotAllowed, "só analista humano age no painel" if attendant.nil?

      attendant
    end

    def ensure_attending!(attendant, conversation)
      return if conversation.state == "with_human" && conversation.attendant_id == attendant.id

      raise NotAllowed, "a conversa não está com este analista"
    end

    def snapshot(conversation)
      {
        state: conversation.state, attendant_id: conversation.attendant_id,
        resolved_at: conversation.resolved_at&.utc&.iso8601(3)
      }
    end
  end
end

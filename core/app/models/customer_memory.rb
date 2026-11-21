# Memória do lojista: resumo das conversas encerradas (resolved ou closed) mais recentes, uma por
# lojista. Gravada só por Conversations::MemoryRefresh.
#
# summary: uma linha por conversa, no locale do lojista.
# entries: uma entrada por conversa, da resolvida mais recentemente para a mais antiga, até
#          MAX_ENTRIES, com as chaves:
#            category       categoria da conversa, ou nil;
#            channel        canal da primeira mensagem (conversations.channel);
#            resolved_by    ai ou analyst, pelo atendente da conversa;
#            resolved_at    conversations.resolved_at, UTC, ISO 8601 com milissegundos;
#            handoff_reason motivo do handoff mais recente, ou nil;
#            first_message  início da primeira mensagem do lojista, até FIRST_MESSAGE_LIMIT caracteres.
class CustomerMemory < ApplicationRecord
  include BrandScoped

  MAX_ENTRIES = 5
  FIRST_MESSAGE_LIMIT = 80

  belongs_to :contact

  validates :summary, presence: true
end

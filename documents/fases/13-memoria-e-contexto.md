# Cloudesk · Memória e contexto

## O que é

A memória do lojista dá continuidade entre os atendimentos. Cada lojista tem no máximo uma `CustomerMemory`, com o resumo das suas conversas encerradas mais recentes, entregue ao agente no contexto da conversa e mostrada ao analista no painel. Ela se apoia em três peças:

- **Recálculo** (`Conversations::MemoryRefresh`): monta a memória do zero a partir das até 5 conversas `resolved` ou `closed` do lojista, com um resumo em texto no locale do lojista e uma entrada estruturada por conversa;
- **Gatilhos:** o `Conversations::MemoryRefreshJob`, enfileirado na resolução da conversa pelo agente ou pelo analista, e o recálculo síncrono na reabertura, dentro do `Conversations::Intake`;
- **Leitura:** o campo `customer_memory` do contexto (`Agents::ConversationContext`), o cartão "Memória do lojista" do painel e o prefixo que o agente mock acrescenta ao `reply` quando a memória tem conversa do mesmo assunto.

O histórico entre canais vem da identidade unificada: telefone, e-mail e id do app do mesmo lojista apontam para o mesmo `Contact`, e a memória é do `Contact`.

## Onde fica no fluxo

```text
resolve do agente (ActionProcessor) ──┐
resolve! do analista (AnalystActions) ┴→ conversation.resolved + MemoryRefreshJob (mesma transação)
                                                  │
                                       jobs-default, fila default
                                                  ▼
                                       Conversations::MemoryRefresh → CustomerMemory
                                                  ▲                       │
Intake: resolved → triage (reabertura) ───────────┘ (mesma transação)    ├→ context_url (customer_memory)
                                                                          ├→ painel (Memória do lojista)
                                                                          └→ agente mock (prefixo do reply)
```

## Por que existe e que valor gera

**Continuidade entre conversas e canais.** O lojista que volta, por qualquer canal, encontra um atendimento que sabe o que já aconteceu: o agente recebe o resumo no contexto e o analista o vê na tela da conversa.

**Sem janela de inconsistência.** O job de recálculo nasce na mesma transação da resolução (outbox implícito no Solid Queue): ou a conversa fica `resolved` e o job existe, ou nenhum dos dois. Na reabertura, o recálculo roda na transação do Intake, e o contexto lido pelo agente nunca traz a conversa reaberta como encerrada.

**Idempotente por construção.** A memória é recalculada do zero a partir do estado atual. A repetição do job, a ordem entre o job e uma reabertura e a reentrega at-least-once chegam ao mesmo resultado, e sem mudança nada é gravado.

**Determinística e auditável.** O resumo vem de um template no locale do lojista, sem LLM: a mesma história gera o mesmo texto. Toda criação, mudança e remoção gera `audit_event` com o antes e o depois.

## Como funciona

### Recálculo

`Conversations::MemoryRefresh.call(brand:, contact_id:, conversation:)` roda dentro do `Tenancy.with_brand` de quem chama:

1. **Trava.** `Contact.lock.find(contact_id)`: os recálculos do mesmo lojista ficam em série, e a gravação por `find_or_initialize_by(contact_id:)` não disputa o índice único `(brand_id, contact_id)`.
2. **Leitura.** As conversas do lojista em `resolved` ou `closed`, por `resolved_at` decrescente e `id` decrescente, até `CustomerMemory::MAX_ENTRIES` (5). Uma consulta traz a primeira mensagem `customer` de cada conversa e outra o handoff mais recente de cada uma.
3. **Decisão.**

| Situação | Efeito |
| - | - |
| Nenhuma conversa encerrada e memória existente | Apaga a memória (`customer_memory.deleted`) |
| Nenhuma conversa encerrada e sem memória | Nada |
| `summary` e `entries` iguais aos gravados | Nada |
| Demais casos | Cria ou atualiza (`customer_memory.updated`) |

A conversa em qualquer outro estado fica fora da memória, inclusive a reaberta, que volta a `triage`.

### Entradas e resumo

Cada conversa vira uma entrada em `customer_memories.entries` (`jsonb`), na ordem da leitura:

| Chave | Conteúdo |
| - | - |
| `category` | `conversations.category`, ou nulo |
| `channel` | `conversations.channel`, o canal da primeira mensagem |
| `resolved_by` | `analyst` quando o atendente da conversa é humano, `ai` nos demais casos; o atendente fica na conversa ao resolver, nos dois caminhos |
| `resolved_at` | `conversations.resolved_at`, UTC, ISO 8601 com milissegundos |
| `handoff_reason` | `reason` do handoff mais recente da conversa, ou nulo |
| `first_message` | Corpo da primeira mensagem do lojista, com os espaços normalizados e cortado em `CustomerMemory::FIRST_MESSAGE_LIMIT` (80) caracteres, reticências incluídas |

O `summary` tem uma linha por entrada, unidas por quebra de linha, com `I18n.with_locale(contact.locale)` e as chaves `conversations.memory.*` de `core/config/locales/pt-BR.yml` e `en-US.yml`:

```text
13/11/2026 · WhatsApp · repasse · resolvida pela IA · escalada: repasse_nao_localizado · "Meu repasse de ontem não caiu"
11/13/2026 · Email · payout · resolved by the AI · escalated: repasse_nao_localizado · "My payout did not arrive"
```

A data é a de `resolved_at` em UTC, no formato do locale (`%d/%m/%Y` em pt-BR, `%m/%d/%Y` em en-US). O trecho do handoff só aparece com `handoff_reason`; sem categoria, a linha diz `sem categoria` ou `no category`.

### Gatilhos

| Momento | Quem chama | Como |
| - | - | - |
| `conversation.resolved` do agente | `Agents::ActionProcessor#resolve` | `MemoryRefreshJob.perform_later(brand_id:, contact_id:, conversation_id:)` dentro do bloco do `Audit::Command` |
| `conversation.resolved` do analista | `Conversations::AnalystActions.resolve!` | O mesmo |
| `conversation.reopened` | `Conversations::Intake` | `MemoryRefresh.call` na mesma transação, logo depois da transição para `triage` |

O `Conversations::MemoryRefreshJob` fica na fila `default`, atendida pelo `jobs-default`, com `enqueue_after_transaction_commit` desligado. Ele abre o `Tenancy.with_brand` da marca dos argumentos, carrega a conversa que disparou o recálculo e chama o serviço. Uma ação recusada e um `NotAllowed` do analista não enfileiram o job, porque nada é gravado.

`conversation.closed` não recalcula: `closed` só existe a partir de `resolved`, e a conversa já está na memória. O fechamento por prazo vencido (`Conversations::CloseExpiredJob` e o próprio Intake) não muda a memória.

### Auditoria

Os dois eventos passam pelo `Audit::Command`, sem webhook e sem `panel: true`:

| Campo | `customer_memory.updated` | `customer_memory.deleted` |
| - | - | - |
| Ator | `system` | `system` |
| Alvo | A `CustomerMemory` | A `CustomerMemory` apagada |
| Conversa | A que disparou o recálculo | A que disparou o recálculo |
| `before` | `summary` e `entries` anteriores; nulo na criação | `summary` e `entries` apagados |
| `after` | `summary` e `entries` gravados | nulo |

Na reabertura, `conversation.reopened` e `customer_memory.updated` (ou `.deleted`) têm o mesmo `trace_id`.

### Concorrência

O `MemoryRefresh` trava só a linha do `Contact`. O job trava o lojista e lê as conversas sem trava; o Intake já tem a conversa travada e trava o lojista depois. As resoluções travam a conversa e só enfileiram o job, sem travar o lojista. Nenhum caminho trava o lojista antes da conversa, então não há ciclo. Um job que roda depois de uma reabertura lê o estado atual e chega ao mesmo resultado que a reabertura gravou.

### Contexto do agente

`Agents::ConversationContext` devolve `customer_memory` nulo quando o lojista não tem memória e, com memória:

| Campo | Conteúdo |
| - | - |
| `summary` | O resumo em texto |
| `updated_at` | `customer_memories.updated_at`, UTC, ISO 8601 com milissegundos |
| `conversations` | As `entries`, na ordem gravada |

O schema `context` de `contracts/v1/` exige `conversations` no objeto, com até 5 itens e todos os campos de cada entrada (detalhes em `documents/fases/04-contrato-de-integracao.md`).

### Painel do analista

A tela da conversa mostra o cartão "Memória do lojista" com o `summary` em `simple_format`, uma linha por conversa, e o horário da última atualização. A lista de conversas anteriores do lojista, em todos os canais, fica ao lado. O cartão não é atualizado em tempo real: a tela mostra a memória vigente no próximo carregamento.

### Uso da memória pelo agente mock

O agente mock usa a memória de forma determinística (`agent_mock/src/agent_mock/memory.py`):

- a conversa anterior relacionada é a mais recente de `customer_memory.conversations` cuja categoria equivale à intenção atual e cujo `resolved_at` fica entre o `received_at` do evento menos `AGENT_MEMORY_WINDOW_DAYS` dias (padrão 30) e o `received_at`, com os dois limites incluídos;
- com ela, todo `reply` das intenções `transacao`, `repasse`, `taxas` e `maquininha` começa com o prefixo no locale da marca, com o assunto e a data UTC da conversa;
- `saudacao`, `resolve` e `escalate` não mudam.

| Intenção | Categorias do Core | Assunto em pt-BR | Assunto em en-US |
| - | - | - | - |
| `transacao` | `transacao`, `transaction` | transação | a transaction |
| `repasse` | `repasse`, `payout` | repasse | payouts |
| `taxas` | `taxas`, `fees` | taxas | fees |
| `maquininha` | `maquininha`, `card_reader` | maquininha | your card reader |

Prefixos: `Vi que você já falou com a gente sobre {assunto} em {data}. ` e `I see you contacted us about {assunto} on {data}. `. A referência é o `received_at` do evento, campo obrigatório do schema `webhook.message-created`, e não o relógio do processo: o mesmo evento com o mesmo contexto gera sempre a mesma ação. O evento sem `received_at` válido é descartado como `invalid_event`.

### Encerramento de demonstração

`bin/rails memory:demo_close CONVERSATION=<id>` (`core/lib/tasks/memory.rake`) procura a conversa nas marcas, trava-a e, em `resolved`, grava `conversation.closed` pelo `Audit::Command`, com ator `operator` e `reason` "demonstração". Fora de `resolved`, ou com id inexistente, termina com erro e não grava nada. O prazo de reabertura da marca não muda. Com a conversa em `closed`, a próxima mensagem do lojista abre outra conversa sem esperar o prazo.

## O que o sistema garante

- Toda resolução, do agente ou do analista, deixa na mesma transação o job que recalcula a memória do lojista.
- A memória contém só conversas `resolved` ou `closed`, as 5 resolvidas mais recentemente, e nunca a conversa reaberta.
- A repetição do recálculo sem mudança no histórico não grava a memória nem cria evento.
- O lojista sem conversa encerrada não tem memória, e o contexto devolve `customer_memory` nulo.
- Toda criação, mudança e remoção da memória gera `audit_event` com ator `system`, a conversa que disparou e o antes e o depois.
- A segunda conversa do mesmo lojista, por outro canal, recebe no contexto o resumo e as entradas da primeira.
- A memória obedece ao RLS da marca: o recálculo com outra marca não encontra o lojista.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Memória e contexto entre interações (conversa, lojista e entre canais) | Memória do lojista recalculada no encerramento, entregue no contexto e no painel, compartilhada entre canais | Identidade unificada e reabertura (F4), histórico da conversa no contexto (F8) |
| Painel do analista com fila de escalas, contexto e histórico | Conteúdo do cartão "Memória do lojista", uma linha por conversa | Tela da conversa e conversas anteriores (F11) |
| Agente mock determinístico | Prefixo do `reply` pela memória relacionada, com a janela pelo `received_at` do evento | Decisão por intenção e ferramentas falsas (F10) |
| Rastreabilidade e auditoria | `customer_memory.updated` e `customer_memory.deleted` com antes e depois | `Audit::Command` e `audit_events` append-only (F1, F2) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · sem backlog crescente | O job de recálculo entra na fila `default` do `jobs-default` a cada resolução; a carga do experimento mede a fila junto com as demais |
| H3 · nenhuma perda nem duplicação | O job nasce na transação da resolução; a repetição dele não grava nada |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 1 · Briefing de handoff avaliado | O analista vê, junto ao briefing, a memória com os motivos de handoff das conversas anteriores |

## Limitações

- **Resumo por template.** O texto lista fatos de cada conversa (data, canal, categoria, quem resolveu, motivo do handoff e início da primeira mensagem); não interpreta o atendimento nem resume o diálogo.
- **Cinco conversas.** Conversas mais antigas que as 5 últimas resolvidas saem da memória.
- **Sem tempo real no painel.** O cartão mostra a memória do último carregamento da tela; a gravação não usa `panel: true`.
- **Job sem retry próprio.** O `MemoryRefreshJob` não declara `retry_on`; uma falha deixa o job na fila de falhas do Solid Queue, com reprocessamento pelo Mission Control. O próximo recálculo do lojista, em outra resolução ou reabertura, refaz a memória do zero.
- **Identidades já ligadas.** A memória é por `Contact`; lojistas com identidades em `Contact` diferentes têm memórias separadas.

## Operação

### Processos

Nenhum processo novo: o `Conversations::MemoryRefreshJob` roda no worker da fila `default` do `jobs-default`.

### Configuração

| Variável | Serviço | Uso | Valor no Compose |
| - | - | - | - |
| `AGENT_MEMORY_WINDOW_DAYS` | `agent-mock` | Dias antes do `received_at` do evento em que uma conversa da memória entra no prefixo do `reply`; inteiro maior ou igual a zero | `30` |

### Banco

A migração `core/db/migrate/20261122120000_add_entries_to_customer_memories.rb` roda com o papel dono e acrescenta `customer_memories.entries jsonb NOT NULL DEFAULT '[]'`. O RLS, os índices e as permissões da tabela não mudam; os `GRANT` do `db/structure.sql` regenerado são os mesmos.

### Inspeção

```text
docker compose exec web bin/rails agent:context CONVERSATION=<id>
docker compose exec web bin/rails memory:demo_close CONVERSATION=<id>
```

### Verificação

Os testes do Core rodam no ambiente de teste: `docker compose exec -e RAILS_ENV=test web bundle exec rspec`; os do agente mock, com `docker compose run --rm agent-mock pytest`.

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/conversations/memory_refresh_spec.rb` | Criação com `customer_memory.updated` e `before` nulo; linha com handoff, sem categoria e com analista; limite de 5 por `resolved_at`; corte em 80 caracteres; locale en-US; conversa aberta fora; repetição sem evento; atualização com `before` e `after`; remoção com `customer_memory.deleted`; nada sem conversa encerrada; outra marca não enxerga o lojista |
| `core/spec/modules/conversations/memory_refresh_job_spec.rb` | Fila `default`; abre a marca e grava a memória; com a marca de outro job, não encontra o lojista |
| `core/spec/modules/agents/action_processor_spec.rb` | `resolve` enfileira o job com marca, lojista e conversa; ação recusada não enfileira |
| `core/spec/modules/conversations/analyst_actions_spec.rb` | `resolve!` enfileira o job; `NotAllowed` não enfileira |
| `core/spec/modules/conversations/intake_spec.rb` | Reabertura tira a conversa da memória com o mesmo `trace_id`; sem outra encerrada, apaga; conversa nova depois do prazo vencido não mexe na memória |
| `core/spec/modules/agents/conversation_context_spec.rb` | `customer_memory` nulo sem memória; com memória, `summary`, `updated_at` e `conversations`, válido pelo schema `context` |
| `core/spec/requests/api/v1/agent/contexts_spec.rb` | Conversa por WhatsApp resolvida pelo agente, job executado, prazo vencido, mensagem por e-mail do mesmo lojista abre outra conversa, e o `GET` assinado da `context_url` traz o resumo e a entrada da primeira |
| `core/spec/requests/panel/conversations_spec.rb` | Memória com duas linhas aparece com a quebra de linha |
| `core/spec/tasks/memory_demo_close_spec.rb` | Fecha a conversa `resolved` com ator `operator`; recusa outro estado, id inexistente e falta de `CONVERSATION` |
| `core/spec/contract/` e `agent_mock/tests/contract/` | Schema `context` com `conversations` e os exemplos válidos e inválidos, em Ruby e em Python |
| `agent_mock/tests/test_memory.py` | Equivalência das categorias das duas marcas; janela pelo `received_at` nos limites; janela zero; conversa mais recente; memória nula ou sem categoria |
| `agent_mock/tests/test_decision.py` | Prefixo nas quatro intenções, nos dois locales; conversa mais recente no prefixo; `saudacao`, `resolve` e `escalate` sem mudança; memória sem relação ou fora da janela; mesma entrada, mesma ação |
| `agent_mock/tests/test_config.py` | `AGENT_MEMORY_WINDOW_DAYS` padrão, válido e inválido |
| `agent_mock/tests/test_processor.py` | Evento sem `received_at` válido descartado como `invalid_event`; janela repassada à decisão |

No Compose, com seeds e `bin/rails simulator:personas`:

- `channel-simulator scenario cross-channel --brand infinitepay --seed 1`: as mensagens de WhatsApp, chat e e-mail caem na mesma conversa, e `agent:context` mostra o histórico dos três canais com `customer_memory` nulo;
- `agent:action TYPE=resolve` na conversa: `customer_memory.updated` em cerca de 1 s, e o cartão "Memória do lojista" aparece na tela da conversa no painel;
- `memory:demo_close`: a conversa vai a `closed`, com `conversation.closed` de ator `operator`;
- o mesmo cenário de novo abre outra conversa do lojista: `agent:context` traz `customer_memory` com o resumo e a entrada da primeira, o painel mostra a memória e a conversa anterior, e o `reply` do agente à mensagem de transação chega ao simulador com o prefixo "Vi que você já falou com a gente sobre transação em ...";
- a conversa nova resolvida e uma nova mensagem do lojista dentro do prazo: `conversation.reopened` e `customer_memory.updated` com o mesmo `trace_id`, e o contexto sem a conversa reaberta.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco (F1) | Tabela `customer_memories` com RLS, índice único por lojista e a coluna `entries` |
| Núcleo transacional (F2) | Toda gravação da memória passa pelo `Audit::Command`; o job nasce na transação da resolução |
| Contrato (F3) | Schema `context` com `customer_memory.conversations` |
| Canais e identidade (F4) | Identidade unificada entre canais e reabertura no `Conversations::Intake`, que recalcula a memória |
| API de ações e contexto (F8) | O `resolve` do agente enfileira o job; o contexto entrega a memória |
| Agente mock (F10) | Prefixo do `reply` pela memória relacionada |
| Handoff e painel (F11) | O `resolve!` do analista enfileira o job; o cartão "Memória do lojista" mostra o resumo |
| Simulador de canais (F5) | Cenário `cross-channel` usado na demonstração |

## Fontes

- `documents/arquitetura.md`, seções "Memória e contexto", "Painel do analista" e "Componentes simulados"
- `documents/fases/04-contrato-de-integracao.md`, seção do contexto da conversa
- `documents/fases/05-canais-de-entrada-e-identidade.md`, seções de identidade e reabertura
- `documents/fases/09-api-de-acoes-e-contexto.md`, seção do contexto
- [Rails Guides · Active Job Basics](https://guides.rubyonrails.org/active_job_basics.html)
- [Rails Guides · Rails Internationalization (I18n) API](https://guides.rubyonrails.org/i18n.html)
- [PostgreSQL · SELECT, The Locking Clause](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)

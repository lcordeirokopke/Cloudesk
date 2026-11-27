# Cloudesk · Handoff, painel do analista e timeout do agente

## O que é

Esta parte leva ao analista humano os casos que a IA não resolve, com o contexto completo, e trata a IA que não responde. Ela tem três peças:

- **Escalação** (`Conversations::Escalate`): grava o handoff e leva a conversa à fila humana de escalação, chamada pelo `escalate` do agente e pela varredura do timeout;
- **Painel do analista** (`/panel`, Hotwire): fila de escalas da equipe, "Pegar próximo", tela da conversa com o briefing, o histórico, as conversas anteriores e a memória do lojista, resposta pelo canal de origem, resolução e avaliação do briefing;
- **Timeout do agente** (`Conversations::AiTimeoutSweepJob`): varredura recorrente que envia mensagem de espera e escala a conversa sem resposta da IA.

O código fica em `core/app/modules/conversations/`, `core/app/controllers/panel/` e `core/app/views/panel/`.

## Onde fica no fluxo

```text
agente → escalate ─┐
                   ├→ Conversations::Escalate → awaiting_human na fila de escalação ─→ painel da equipe (refresh)
varredura (15 s) ──┘                                                                    │
     │                                                          "Pegar próximo" (Distributor.next_for)
     └→ mensagem de espera na metade do SLA                                             │
                                                    with_human → resposta pelo canal de origem → resolved
```

A escalação é a fronteira entre a IA e a operação humana. Depois dela, a conversa sai do caminho do Broker: o webhook não é enviado com a conversa fora de `with_ai`, e uma ação atrasada da IA recebe `409 rejected`.

## Por que existe e que valor gera

**O analista recebe o caso pronto.** O briefing do handoff chega como cartão: o problema em uma frase, o que a IA tentou, as ferramentas consultadas e os retornos, o sentimento, o próximo passo sugerido e a confiança. O analista não precisa reler a conversa para começar.

**O caso vai para quem resolve.** A fila de IA aponta uma fila humana de escalação, editável como dado. A conversa escalada da fila prioritária de repasse vai para a fila financeira, com a mesma prioridade e o SLA da fila humana.

**Nenhum lojista fica sem resposta.** Se a IA não responde, a varredura envia uma mensagem de espera na metade do SLA e escala no SLA inteiro. Não existe timer por mensagem: uma única consulta recorrente cobre todas as conversas.

**Atualização sem recarregar.** A conversa escalada aparece na fila da equipe na hora, e a mensagem nova do lojista aparece na tela da conversa, sem polling no navegador.

**Toda decisão explicada.** A tela da conversa mostra por que ela caiu na fila atual: a regra e a versão, a classificação e a escalação, lidas de `audit_events`. Toda transição do painel grava `audit_event` com o analista como ator.

**Robustez demonstrável.** Os modos de falha do agente mock (`documents/fases/11-agente-mock.md`) exercitam a varredura do timeout: com o agente atrasando ou sem responder, o lojista recebe a espera e chega a um analista.

## Como funciona

### Fila de escalação

A coluna `queues.escalation_queue_id` aponta uma fila humana da mesma marca (FK composta `(brand_id, escalation_queue_id)`). O model `Routing::Queue` valida que a fila de escalação tem `first_attendant` `human` e é diferente da própria fila.

| Fila (seeds) | Fila de escalação |
| - | - |
| `ip-financeiro-prioritaria`, `ip-transacoes` | `ip-financeiro` |
| `jim-finance-priority`, `jim-transactions` | `jim-finance` |
| `ip-financeiro`, `ip-urgente`, `ip-maquininha`, `ip-suporte-geral`, `jim-finance`, `jim-urgent`, `jim-card-reader`, `jim-general-support` | nenhuma |

### Escalação

`Conversations::Escalate.call(conversation:, reason:, summary:, context:, actor_type:, actor_id:)` roda dentro do `Tenancy.with_brand` de quem chama, com a conversa já travada:

1. **Destino.** A `escalation_queue` da fila atual ou, sem ela, a própria fila atual.
2. **Contagem.** Conta as conversas abertas do destino, sem trava. A escalação não confere a capacidade; a contagem e a capacidade vão para o evento.
3. **Evento.** `conversation.escalated`, com `panel: true`, ator e motivo de quem chama: cria o `Handoff` e leva a conversa a `awaiting_human`, sem atendente, com `queued_at`, no destino. A prioridade fica a mesma; ao mudar de fila, a conversa recebe o SLA do destino.

| Campo do evento | Conteúdo |
| - | - |
| `before`, `after` | Estado, fila, atendente, SLA e `queued_at` |
| `payload` | `handoff_id`, `from_queue`, `to_queue`, `moved`, `open_conversations`, `capacity` |

| Quem chama | Ator | Motivo | Resumo e contexto |
| - | - | - | - |
| `Agents::ActionProcessor#escalate` | `ai`, atendente da conversa | `reason` da ação | `summary` e `context` da ação |
| `Conversations::AiTimeoutSweepJob` | `system` | `ai_timeout` | Resumo no locale da marca (`conversations.ai_timeout.summary`, "A IA não respondeu em N min."), contexto `{}` |

O evento `agent.escalate` da ação continua gravado à parte, pelo `ActionProcessor`.

### Timeout do agente

A tarefa recorrente `ai_timeout_sweep` (`core/config/recurring.yml`, `every 15 seconds`, fila `default`) roda o `Conversations::AiTimeoutSweepJob` no `jobs-default`. Em cada marca, em `Tenancy.with_brand`, ela faz duas passagens nesta ordem, em lotes de 100:

| Passagem | Conversa em `with_ai` cuja última mensagem do lojista | Ação |
| - | - | - |
| 1 · Escalação | tem `sla_minutes` ou mais, sem mensagem `ai` depois dela | `Conversations::Escalate` com motivo `ai_timeout` |
| 2 · Espera | tem metade do SLA ou mais, sem mensagem `ai` nem `system` depois dela | Mensagem `system` no locale da marca (`conversations.ai_timeout.wait_message`), em resposta à última mensagem do lojista, pelo canal dela, com motivo `ai_timeout_wait` |

- A última mensagem do lojista é a de maior `sequence` (`CROSS JOIN LATERAL`). O prazo conta da criação dela.
- A espera sai uma vez por mensagem do lojista: a própria mensagem `system` encerra a passagem 2. Ela não encerra a passagem 1, e o prazo da escalação não reinicia.
- A conversa vencida no SLA inteiro sem espera é só escalada: a passagem 1 vem antes, e a conversa sai de `with_ai`.
- Um `categorize` aceito não grava mensagem e não conta como resposta.
- As conversas são lidas com `FOR UPDATE OF conversations SKIP LOCKED`. A conversa travada por uma ação do agente, por uma mensagem de entrada ou por outra varredura fica para a execução seguinte.
- Depois da trava, as condições são conferidas de novo em Ruby, porque a reavaliação do `FOR UPDATE` cobre a linha da conversa, mas não as subconsultas em `messages`.
- Uma ação da IA que chega depois da escalação recebe `409 rejected`, porque a conversa saiu de `with_ai`.
- Os modos de falha `delay`, `drop` e `stale` do agente mock (`documents/fases/11-agente-mock.md`) deixam a conversa sem resposta aceita da IA e levam a ela.

### Painel do analista

| Rota | Controller | Função |
| - | - | - |
| `GET /panel` | `Panel::SessionsController#index` | Marcas e analistas humanos com equipe |
| `POST /panel/session` | `#create` | Grava a marca e o analista na sessão (`analyst=<marca>:<id>`) |
| `DELETE /panel/session` | `#destroy` | Limpa a sessão do painel |
| `GET /panel/queue` | `Panel::QueuesController#show` | Fila de escalas da equipe e "Minhas conversas" |
| `POST /panel/assignments` | `Panel::AssignmentsController#create` | "Pegar próximo" |
| `GET /panel/conversations/:id` | `Panel::ConversationsController#show` | Tela da conversa |
| `GET /panel/conversations/:conversation_id/messages/:message_id/timeline` | `Panel::TimelinesController#show` | Linha do tempo de uma mensagem do lojista (`documents/fases/15-observabilidade.md`) |
| `POST /panel/conversations/:conversation_id/replies` | `Panel::RepliesController#create` | Resposta do analista |
| `POST /panel/conversations/:conversation_id/resolution` | `Panel::ResolutionsController#create` | Resolução |
| `POST /panel/handoffs/:handoff_id/rating` | `Panel::HandoffRatingsController#create` | Avaliação do briefing (`rating=useful` ou `not_useful`) |

**Acesso.** Todo o `/panel` fica atrás de HTTP basic auth com `PANEL_USER` e `PANEL_PASSWORD`, lidos a cada requisição (`Panel::BaseController`); sem os dois preenchidos, o acesso é negado. Dentro dele, o login é simulado, como o do widget de chat: a escolha do analista fica em `session[:panel_brand]` e `session[:panel_attendant_id]`, e sem ela as páginas voltam à escolha. Só aparece e só entra analista `human` com equipe, conferido na marca da sessão. Toda leitura roda em `Tenancy.with_brand` da marca da sessão: conversa de outra marca responde `404`.

**Fila de escalas.** Conversas em `awaiting_human` nas filas da equipe do analista, por prioridade (maior primeiro), `queued_at` e id, com o motivo e o resumo do último handoff, o tempo na fila e o SLA restante (`queued_at` mais `sla_minutes` menos agora; negativo em destaque). Conversa roteada direto para a fila humana aparece sem handoff. Abaixo, as conversas `with_human` do analista e a capacidade usada.

**Pegar próximo.** O caso é atribuído só pela distribuição por capacidade da triagem (`Routing::Distributor.next_for`): a conversa de maior prioridade e há mais tempo na fila das filas da equipe, com `FOR UPDATE SKIP LOCKED`. Sem caso ou na capacidade, volta à fila com o aviso "Nenhum caso disponível". A fila é visível, e qualquer conversa da marca abre só para leitura.

**Tela da conversa.**

| Bloco | Conteúdo |
| - | - |
| Cabeçalho | Estado, fila, prioridade, SLA e atendente |
| Histórico | Mensagens por `sequence`, com autor, atendente, canal e horário no fuso da equipe do analista |
| Briefing do handoff | Último handoff: resumo, motivo, horário, intenção, sentimento, confiança, próximo passo sugerido, entidades, tentativas, ferramentas e retornos; tempo até a primeira resposta humana; avaliação |
| Por que caiu aqui? | `Conversations::RoutingExplanation` (diferencial 3) |
| Memória do lojista | `summary` da `CustomerMemory` do lojista, quando existe, com uma linha por conversa encerrada (`simple_format`) e o horário da atualização; o cartão não é atualizado em tempo real (`documents/fases/13-memoria-e-contexto.md`) |
| Conversas anteriores | Até 10 outras conversas do lojista, em todos os canais, com as mensagens, só leitura |

O formulário de resposta e o botão "Resolver" aparecem só com a conversa em `with_human` atribuída ao analista; a avaliação, com a conversa do analista em `with_human` ou `resolved` e o briefing ainda sem avaliação.

**Interface.** Em pt-BR para as duas marcas, como o widget de chat. Estilos próprios em `core/app/assets/stylesheets/panel.css`, sob `body.panel`, com tema claro e escuro pelo `prefers-color-scheme`.

### Ações do analista

`Conversations::AnalystActions` roda cada ação em `Tenancy.with_brand` da marca do analista, com `Conversation.lock`. Fora das exigências, levanta `NotAllowed`, nada é gravado, e o controller volta à conversa com o motivo no aviso.

| Ação | Exige | Efeito |
| - | - | - |
| `reply!(analyst:, conversation_id:, text:)` | Conversa `with_human` do analista; texto não vazio | Responde à última mensagem do lojista por `Conversations::Outbound.append!` (autor `analyst`, atendente o analista): a resposta sai pelo canal e pela `BrandChannel` dessa mensagem |
| `resolve!(analyst:, conversation_id:)` | Conversa `with_human` do analista | `conversation.resolved`, ator `analyst`, `panel: true`: `with_human` → `resolved`, com `resolved_at`; o atendente fica na conversa; nenhuma mensagem ao lojista; enfileira na mesma transação o `Conversations::MemoryRefreshJob`, que recalcula a memória do lojista |
| `rate_handoff!(analyst:, handoff_id:, rating:)` | Conversa do handoff atribuída ao analista, em `with_human` ou `resolved`; handoff sem avaliação; `rating` em `useful` ou `not_useful` | `handoff.rated`, ator `analyst`, `panel: true`: grava `rating`, `rated_by_id` e `rated_at` |

O `payload` do `handoff.rated` leva `handoff_id`, `rating` e `first_human_response_seconds`: segundos da criação do handoff até a primeira mensagem de analista da conversa (`Handoff#first_human_response_at`), ou `null` sem resposta.

### Tempo real

O `Audit::Command` aceita `panel: true`. Com ele, depois de gravar o `audit_event`, enfileira na mesma transação o `Conversations::PanelBroadcastJob` (fila `channels`, `enqueue_after_transaction_commit` desligado), com `brand_id`, a conversa e o `team_id` da fila em que ela está depois da mudança. Se a transação falha, não existe job.

O job envia um Turbo Stream `refresh` (`Turbo::StreamsChannel.broadcast_refresh_to`) ao stream da conversa e, com equipe, ao da equipe, e não lê o domínio. As páginas assinam o stream com `turbo_stream_from`, e o layout do painel declara `turbo_refreshes_with method: :morph, scroll: :preserve`: no `refresh`, a página busca de novo a própria URL e aplica a diferença, mantendo a rolagem.

| Stream (`Conversations::PanelBroadcast`) | Assinado por |
| - | - |
| `panel:team:<team_id>` | Fila de escalas |
| `panel:conversation:<id>` | Tela da conversa |

| Evento gravado com `panel: true` | Quem grava |
| - | - |
| `conversation.routed` com atendente inicial humano | `Routing::Route` |
| `conversation.assigned` | `Routing::Distributor` |
| `conversation.escalated` | `Conversations::Escalate` |
| `conversation.resolved` do analista, `handoff.rated` | `Conversations::AnalystActions` |
| `message.created` com a conversa em `awaiting_human` ou `with_human` (`Conversation::HUMAN_STATES`) | `Conversations::Intake` e `Conversations::Outbound` |

### "Por que caiu aqui?"

`Conversations::RoutingExplanation.for(conversation)` lê de `audit_events` o último evento de cada tipo da conversa:

| Parte | Evento | Conteúdo |
| - | - | - |
| `routed` | `conversation.routed` | Regra (nome e `rule_id`) e `rule_version` do `audit_event`, fila, prioridade, SLA, atendente inicial, transbordo e a cadeia de filas com abertas e capacidade, gatilho (`intake` ou `categorize`) |
| `classified` | `conversation.classified` | Categoria, urgência, palavras encontradas por categoria e de urgência, pontuação, versão das listas do classificador, ou a indicação de que a categoria veio da IA |
| `escalated` | `conversation.escalated` | Fila de origem e de destino, se mudou, motivo e ator |

As versões de regra são imutáveis: a explicação continua válida depois que a regra muda.

### SLA de demonstração

`core/lib/tasks/panel.rake` publica, por `Routing::RulePublisher`, uma nova versão da regra genérica ativa da marca, com outro `then.sla_minutes`. A mudança vale para as conversas roteadas depois dela pela regra genérica, e cada publicação grava `routing_rule.published`. Nas seeds, a regra genérica recebe as mensagens sem categoria e sem urgência de lojista de baixo volume ou sem segmento, como a saudação do simulador enviada com `--contacts new`.

| Task | Efeito |
| - | - |
| `bin/rails panel:demo_sla BRAND=<slug> MINUTES=<n>` | SLA de `n` minutos na regra genérica |
| `bin/rails panel:demo_sla_reset BRAND=<slug>` | SLA da fila da regra genérica (120 min nas duas marcas das seeds) |

## O que o sistema garante

- Toda escalação passa por `Conversations::Escalate`, cria um `Handoff` e grava `conversation.escalated` com origem, destino, contagem e capacidade.
- A conversa escalada de uma fila com fila de escalação vai para ela, com a mesma prioridade e o SLA do destino.
- Uma conversa em `with_ai` sem mensagem da IA depois da última mensagem do lojista recebe uma única mensagem de espera na metade do SLA e é escalada no SLA inteiro.
- A varredura não age sobre conversa travada nem sobre conversa que deixou de cumprir as condições depois da trava.
- O analista só recebe caso das filas da própria equipe, por "Pegar próximo", dentro da capacidade.
- Só o analista atribuído responde e resolve a conversa `with_human`, e só ele avalia o briefing, uma vez.
- A resposta do analista sai pelo canal e pelo número ou e-mail da última mensagem do lojista.
- A mudança gravada com `panel: true` e o job de atualização do painel são gravados na mesma transação.
- Nenhum dado de outra marca aparece no painel.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Painel do analista com fila de escalas, contexto e histórico | Fila de escalas da equipe, tela da conversa com briefing, histórico, conversas anteriores e memória, em tempo real | Montagem da memória do lojista (F12) |
| Interface de conversa entre cliente e atendente | Resposta do analista pelo canal de origem e mensagens novas do lojista na tela | Widget de chat (F4) e resposta da IA (F8) |
| Handoff com resumo e contexto, preservando o histórico | Fila de escalação, cartão do briefing, histórico na mesma conversa | Gravação do briefing pelo `escalate` (F8) |
| Triagem, priorização e distribuição entre IA e analistas | "Pegar próximo" pela distribuição por capacidade; escalação da IA para a fila humana | Classificador, regras e `Distributor` (F6) |
| Rastreabilidade e auditoria das decisões | `conversation.escalated`, `conversation.assigned`, `conversation.resolved` e `handoff.rated` com o ator; "Por que caiu aqui?" | Linha do tempo por mensagem (F14) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H3 · nenhuma perda nem duplicação | O lojista sem resposta da IA recebe a espera e chega a um analista, o que o modo `drop` do agente mock demonstra |
| H1 · sem backlog crescente | A varredura roda a cada 15 s no `jobs-default`, pelos índices parciais `index_conversations_with_ai` e `index_messages_customer_by_sequence` |
| H4 · latência ponta a ponta | O broadcast do painel roda na fila `channels`, a mesma das entregas, e entra na disputa por esse worker |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 1 · Briefing de handoff avaliado pelo analista | Cartão com problema, tentativas, ferramentas e retornos, sentimento, próximo passo e confiança; avaliação útil ou não útil, uma vez, com `handoff.rated`; tempo até a primeira resposta humana no cartão e no evento |
| 3 · "Por que caiu aqui?" | A tela da conversa mostra regra, versão, fila, prioridade, SLA, transbordo, classificação e escalação |
| 4 · Modos de falha do agente mock | A varredura do timeout trata a falta de resposta dos modos `delay`, `drop` e `stale`; os modos ficam no agente mock (F10) |
| 2 · Cockpit operacional | O motivo de cada escalação (inclusive `ai_timeout`), a avaliação e o tempo até a primeira resposta ficam em `audit_events` e `handoffs`, dados do painel da F14 |

## Limitações

- **Login simulado.** Um único usuário e senha de basic auth dá acesso ao painel, e a escolha do analista na sessão não tem senha própria. Qualquer pessoa com a credencial age como qualquer analista.
- **Escalação sem conferência de capacidade.** A fila de escalação recebe a conversa mesmo cheia; a contagem fica só no evento.
- **Atribuição só por pedido.** Não existe atribuição automática a um analista livre: o caso espera até alguém pedir o próximo.
- **Refresh da página inteira.** Cada mudança faz cada página aberta buscar de novo a própria URL. Com muitos analistas na mesma equipe, cada escalação gera uma requisição por página aberta.
- **Refresh só na equipe do destino.** O stream da equipe recebe o `refresh` pela fila em que a conversa está depois da mudança. Se a fila de escalação for de outra equipe, a página da equipe de origem não é atualizada. Nas seeds, as duas filas são da mesma equipe.
- **Granularidade de 15 s.** A espera e a escalação saem até 15 s depois do prazo, mais a duração da varredura.
- **Prazo pela última mensagem do lojista.** Uma nova mensagem do lojista antes do prazo reinicia a contagem da espera e da escalação.
- **Índices da varredura.** A consulta usa os índices parciais `index_conversations_with_ai` e `index_messages_customer_by_sequence`. Com poucas conversas e metade delas em `with_ai`, o planejador lê `conversations` inteira, que custa menos; o índice de `with_ai` entra quando as conversas em `with_ai` são uma fração pequena da tabela (`documents/fases/16-robustez-e-escala.md`).
- **Handoff do timeout sem contexto.** O cartão de uma escalação por `ai_timeout` mostra só o motivo e o resumo do sistema.
- **Avaliação definitiva.** O briefing é avaliado uma vez e não pode ser corrigido.
- **Interface em pt-BR.** O painel não segue o locale da marca; as mensagens ao lojista seguem.

## Operação

### Processos

Nenhum serviço novo. A varredura roda no `jobs-default`, como tarefa recorrente, e o `Conversations::PanelBroadcastJob`, no worker da fila `channels` do mesmo serviço. O painel é servido pelo `web`, e o Action Cable usa o Solid Cable.

| Tarefa recorrente | Classe | Agenda |
| - | - | - |
| `ai_timeout_sweep` | `Conversations::AiTimeoutSweepJob` | `every 15 seconds` |

### Configuração

| Variável | Uso | Valor no Compose |
| - | - | - |
| `PANEL_USER` | Usuário do basic auth do painel | `.env` |
| `PANEL_PASSWORD` | Senha do basic auth do painel; vazia, nega o acesso | `.env` |

Os textos da varredura ficam em `core/config/locales/pt-BR.yml` e `en-US.yml`, em `conversations.ai_timeout`.

### Banco

A migração `core/db/migrate/20261121120000_add_escalation_queue_and_handoff_rating.rb` roda com o papel dono:

| Coluna | Tipo | Restrição |
| - | - | - |
| `queues.escalation_queue_id` | `uuid` | FK `(brand_id, escalation_queue_id)` → `queues (brand_id, id)`, sem `ON DELETE`; índice `(brand_id, escalation_queue_id)` |
| `handoffs.rating` | `varchar` | `CHECK (rating IN ('useful', 'not_useful'))` |
| `handoffs.rated_by_id` | `uuid` | FK `(brand_id, rated_by_id)` → `attendants (brand_id, id)`; índice `(brand_id, rated_by_id)` |
| `handoffs.rated_at` | `timestamp(6)` | |

O RLS e as permissões das duas tabelas não mudam; os `GRANT` do `db/structure.sql` regenerado são os mesmos.

### Verificação

Os testes rodam no ambiente de teste: `docker compose exec -e RAILS_ENV=test web bundle exec rspec`.

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/conversations/escalate_spec.rb` | Com fila de escalação, muda fila e SLA e mantém a prioridade; sem ela, fica na fila; contagem e capacidade no payload, sem conferir capacidade; handoff e evento com ator e motivo; job do painel com a equipe do destino |
| `core/spec/modules/conversations/ai_timeout_sweep_job_spec.rb` | Espera na metade do SLA, uma vez; escalação no SLA com handoff `ai_timeout` depois da espera; só escalação passado o SLA; resposta da IA cancela; prazo pela última mensagem do lojista; conversa fora de `with_ai` ignorada; locale de cada marca; conversa travada por outra conexão pulada |
| `core/spec/modules/conversations/analyst_actions_spec.rb` | Resposta pelo canal da última mensagem do lojista; resolução; recusa de outro analista, de conversa fora de `with_human`, de texto vazio e de outra marca; avaliação única com `handoff.rated` e o tempo até a primeira resposta |
| `core/spec/modules/conversations/panel_broadcast_job_spec.rb` | `refresh` nos streams da conversa e da equipe; sem equipe, só na conversa; fila `channels` |
| `core/spec/modules/conversations/routing_explanation_spec.rb` | Último `conversation.routed` e `conversation.classified`, escalação com origem e destino, roteamento mais recente |
| `core/spec/modules/audit/command_spec.rb` | `panel: true` enfileira o job na transação com conversa e equipe; sem `panel`, não; a falha da transação não deixa o job; recusa `panel: true` sem conversa |
| `core/spec/modules/agents/action_processor_spec.rb` | `escalate` com fila de escalação; ação da IA depois da escalação pelo timeout recebe `rejected` |
| `core/spec/modules/routing/route_spec.rb`, `distributor_spec.rb`, `core/spec/modules/conversations/intake_spec.rb` | Job do painel só na atribuição à fila humana, na atribuição ao analista e nas mensagens com a conversa em estado humano |
| `core/spec/models/handoff_spec.rb`, `routing_queue_spec.rb` | `first_human_response_at`; validação e `CHECK` da avaliação; fila de escalação humana, diferente da própria e da mesma marca |
| `core/spec/requests/panel/sessions_spec.rb` | `401` sem credencial, com senha errada e com a senha do ambiente vazia; lista de analistas; login, troca e recusa de analista de outra marca |
| `core/spec/requests/panel/conversations_spec.rb` | Fila da equipe com motivo e stream; outra equipe não vê; "Pegar próximo" com caso e sem caso; tela com cartão, explicação, conversas anteriores e memória, com uma linha por conversa; `404` de outra marca; resposta, resolução e avaliação; recusa de outro analista |
| `core/spec/tasks/panel_demo_sla_spec.rb` | Nova versão da regra genérica com o SLA, só na marca; reset ao SLA da fila; conversa roteada depois pela regra genérica recebe o SLA; recusa de marca e minutos inválidos |
| `core/spec/seeds_spec.rb` | Filas de escalação das seeds e reexecução sem duplicar |

No Compose:

- `ai_timeout_sweep` aparece nas tarefas recorrentes do Mission Control (`/jobs`) com `every 15 seconds`, e as execuções ficam às :00, :15, :30 e :45 de cada minuto, sem falhas;
- uma mensagem de repasse de lojista `alto_tpv` pelo webhook do WhatsApp leva o mock a `escalate`; a conversa vai de `ip-financeiro-prioritaria` para `ip-financeiro`, com SLA 60 e prioridade 90, e aparece na fila da equipe Financeiro com o motivo; "Pegar próximo" a atribui; a resposta do analista chega ao simulador pelo WhatsApp em cerca de 1 s; a nova mensagem do lojista aparece na tela; resolver leva a `resolved`; a avaliação mostra o tempo até a primeira resposta;
- um cliente do `/cable` inscrito nos streams recebe `refresh` no stream da conversa na atribuição, na resposta, na mensagem do lojista, na resolução e na avaliação, e no stream da equipe na escalação;
- a tela mostra a regra "InfinitePay · Repasse · Alto volume" versão 1, fila, prioridade, SLA, transbordo e a escalação de `ip-financeiro-prioritaria` para `ip-financeiro`;
- com `panel:demo_sla BRAND=infinitepay MINUTES=1` e o agente em `drop`, duas conversas novas da regra genérica receberam a mensagem de espera aos 37 e aos 40 s e foram escaladas com handoff `ai_timeout` aos 67 e aos 70 s;
- com o agente em `stale`, a conversa cuja ação recebe `409 stale` recebe a espera 33 s e é escalada 63 s depois da última mensagem do lojista.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco e entidades (F1) | `handoffs`, `queues`, as transições `with_ai` → `awaiting_human` → `with_human` → `resolved` e o RLS de todas as leituras do painel |
| Núcleo transacional (F2) | `Audit::Command` com `panel: true` e o outbox do job do painel |
| Canais (F4) | A resposta do analista sai pelo mesmo `Channels::DeliveryJob` da IA; o widget de chat inspira o login simulado |
| Triagem e distribuição (F6) | `Routing::Distributor.next_for` em "Pegar próximo"; eventos de roteamento lidos em "Por que caiu aqui?" |
| Saída para o Broker (F7) | O webhook não sai com a conversa fora de `with_ai` |
| API de ações (F8) | O `escalate` chama `Conversations::Escalate`; a ação atrasada recebe `409 rejected` |
| Agente mock (F10) | O briefing do `escalate`; os modos de falha `delay`, `drop` e `stale` exercitam a varredura |
| Memória (F12) | Preenche o `CustomerMemory` mostrado na tela da conversa |
| Admin (F13) | Edição de filas, inclusive a fila de escalação |
| Observabilidade (F14) | Pareto de motivos de escalação, avaliação e tempo até a primeira resposta; linha do tempo por mensagem |
| Robustez e escala (F15) | Índices parciais da varredura e da capacidade do analista; heartbeat do Solid Queue e `recover_interrupted_webhooks` a cada 15 s |

## Fontes

- `documents/arquitetura.md`, seções "Timeout do agente", "Handoff com resumo e contexto", "Painel do analista" e "Diferenciais"
- `documents/fases/02-banco-multi-marca-e-entidades.md`, seção "Máquina de estados da conversa"
- `documents/fases/07-triagem-roteamento-e-distribuicao.md`
- `documents/fases/09-api-de-acoes-e-contexto.md`
- `documents/fases/11-agente-mock.md`, seção "Um evento, do consumo à publicação"
- [Turbo Handbook · Page Refreshes](https://turbo.hotwired.dev/handbook/page_refreshes)
- [Solid Queue](https://github.com/rails/solid_queue)
- [PostgreSQL · SELECT, The Locking Clause](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE)

# Cloudesk · F8 · API de ações e de contexto

## Objetivo

A F8 permite que o agente atue na plataforma como um atendente. A API de ações recebe do Broker as ações `reply`, `escalate`, `categorize` e `resolve`, assinadas com HMAC-SHA256 e timestamp, com idempotência por `Idempotency-Key` e recusa com `409` da ação desatualizada ou com a conversa fora de `with_ai`. O `audit_event` de cada ação guarda as ferramentas consultadas e os carimbos de horário de cada salto. O endpoint de contexto entrega ao agente o histórico da conversa.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Segredos | `AGENT_ACTIONS_SECRET` assina as chamadas do Broker à API de ações; `AGENT_CONTEXT_SECRET` assina o `GET` da `context_url` pelo agente. Os dois ficam no `.env` e no bloco `rails-environment` do Compose |
| Endpoint de ações | Único: `POST /api/v1/agent/actions`. O corpo é o valor Kafka de `agent.outbound`, sem alteração; marca e conversa vêm do corpo assinado |
| Endpoint de contexto | `GET /api/v1/agent/brands/<brand>/conversations/<conversation_id>/context`. A marca fica no caminho e entra na assinatura |
| Conversa fora de `with_ai` | `409` com status `rejected`: `conversation_id`, `event_id` do `audit_event` da recusa e `state` da conversa |
| Ação desatualizada | `409` com status `stale` quando `based_on_sequence` é menor que a sequência da última mensagem do lojista. Vale para as quatro ações |
| Recusas guardadas | `stale` e `rejected` são resultado final da chave e ficam em `processed_events`. A repetição devolve o mesmo corpo e o mesmo código, sem novo `audit_event` |
| Evento da ação | `agent.reply`, `agent.escalate`, `agent.categorize` e `agent.resolve`, com o corpo completo da ação, a `Idempotency-Key` e o `received_at` do Core. Os eventos de domínio são gravados à parte, na mesma transação. As recusas gravam `agent.action.stale` e `agent.action.rejected` |
| Ator | `actor_type: "ai"`; `actor_id` é o atendente da conversa e, na recusa por estado, o atendente IA da marca |
| Concorrência | Um único `Tenancy.with_brand` com `FOR UPDATE` na conversa: as ações da mesma conversa, inclusive as duplicadas simultâneas, ficam serializadas |
| Contexto | Histórico em ordem crescente de `sequence`, `customer_memory` nulo até a F12, sem cache |
| Prova sem Broker | `bin/rails agent:action` e `bin/rails agent:context` |

## Arquivos

### Contrato (`contracts/v1/`)

| Arquivo | Conteúdo |
| - | - |
| `schemas/action-response.json` | Status `rejected` com `conversation_id`, `event_id` e `state` (um dos estados fora de `with_ai`) |
| `examples/action-response/valid/rejected.json` | Recusa com a conversa em `with_human` |
| `examples/action-response/invalid/rejected-sem-state.json` | Recusa sem `state` |
| `schemas/webhook.message-created.json` | Pattern da `context_url` com o slug da marca |
| `examples/webhook.message-created/**` | `context_url` com a marca de cada exemplo |
| `examples/webhook.message-created/invalid/context-url-sem-marca.json` | `context_url` sem a marca |
| `signature-vectors.json` | O corpo do vetor de webhook e os vetores de `GET` com o caminho com a marca; assinaturas conferidas por `openssl dgst -sha256 -hmac` |

### Core (`core/`)

| Arquivo | Conteúdo |
| - | - |
| `lib/contract/message_created.rb` | `context_url(brand, conversation_id)` |
| `app/modules/agents/settings.rb` | `agent_actions_secret` e `agent_context_secret` |
| `app/modules/agents/action_processor.rb` | Conferências, trava, idempotência, estado, sequência, execução de cada tipo e resultado no formato do `action-response` |
| `app/modules/agents/conversation_context.rb` | Corpo do schema `context` |
| `app/models/attendant.rb` | `Attendant.first_ai`: o atendente IA da marca corrente, o primeiro por nome; usado pelo `Routing::Route` e pela recusa |
| `app/controllers/api/v1/agent/base_controller.rb` | `ActionController::API`, verificação da assinatura com o segredo de cada rota e erros no formato do contrato |
| `app/controllers/api/v1/agent/actions_controller.rb` | `POST /api/v1/agent/actions` |
| `app/controllers/api/v1/agent/contexts_controller.rb` | `GET /api/v1/agent/brands/:brand/conversations/:conversation_id/context` |
| `config/routes.rb` | Rotas da API do agente |
| `lib/tasks/agent.rake` | `agent:action` e `agent:context` |

### Raiz

| Arquivo | Conteúdo |
| - | - |
| `.env.example` | `AGENT_ACTIONS_SECRET` e `AGENT_CONTEXT_SECRET` |
| `compose.yaml` | As duas variáveis no bloco `rails-environment` |

## Contexto da conversa

`GET /api/v1/agent/brands/<brand>/conversations/<conversation_id>/context`, assinado pelo agente com `AGENT_CONTEXT_SECRET` sobre o caminho com a query string (`request.fullpath`).

- A assinatura é conferida antes de qualquer leitura do banco.
- A marca vem do slug do caminho. A conversa é lida dentro de `Tenancy.with_brand` dessa marca; com o RLS, a conversa de outra marca não é visível e responde `404`.
- Marca inexistente e id que não é UUID também respondem `404 not_found`.
- O corpo vem de `Agents::ConversationContext`: `conversation` (`id`, `brand`, `channel`, `state`, `last_sequence`), `messages` em ordem crescente de `sequence` (`sequence`, `author`, `channel`, `text`, `created_at`) e `customer_memory` nulo.
- O endpoint responde em qualquer estado da conversa: é o agente quem decide, pelo estado e pelas sequências, se o evento ainda pede ação.

**Por que a marca no caminho.** O RLS exige a marca na transação antes de qualquer linha de domínio ficar visível (`documents/fases/02-banco-multi-marca-e-entidades.md`). Com a marca no caminho, ela entra no texto assinado: uma assinatura válida para uma marca não serve para outra.

## API de ações

`POST /api/v1/agent/actions`, assinado pelo Broker com `AGENT_ACTIONS_SECRET`, com o header `Idempotency-Key`.

### Códigos

| Código | Corpo | Quando |
| - | - | - |
| `200` | `accepted` | Ação aceita, inclusive a repetição da chave |
| `409` | `stale` | `based_on_sequence` menor que a última mensagem do lojista |
| `409` | `rejected` | Conversa fora de `with_ai` |
| `400` | `error` `missing_idempotency_key` | Sem o header `Idempotency-Key` |
| `401` | `error` `invalid_signature` ou `expired_timestamp` | Assinatura ausente ou que não confere; timestamp fora da janela de 300 s |
| `404` | `error` `not_found` | Marca do corpo inexistente; conversa inexistente na marca |
| `422` | `error` `invalid_payload` | JSON inválido; corpo fora do schema `action`; `Idempotency-Key` diferente da derivada do corpo (`Contract::IdempotencyKey.for_action`); `inbound_event_id` que não é um `message.created` da conversa; `based_on_sequence` maior que `last_sequence` |

Os dois `409` são resultado final para o Broker: sem retry e sem DLQ. Os demais `4xx` vão para a DLQ no Broker (F9).

### Ordem do processamento

O controller confere a assinatura, o header `Idempotency-Key` e o JSON, e chama `Agents::ActionProcessor`. O processador:

1. confere o schema `action` e a `Idempotency-Key` derivada, sem tocar no banco;
2. busca a marca pelo slug do corpo;
3. abre um único `Tenancy.with_brand` e trava a conversa com `FOR UPDATE`;
4. consulta `processed_events`: com a chave existente, devolve o corpo guardado, com o código do status dele;
5. confere o `inbound_event_id` e o limite de `based_on_sequence` (`422`);
6. confere o estado: fora de `with_ai`, grava `agent.action.rejected` e responde `rejected`;
7. confere a sequência: com mensagem do lojista mais nova, grava `agent.action.stale` e responde `stale`;
8. executa a ação dentro do `Audit::Command` do evento da ação;
9. grava o corpo da resposta em `processed_events` (`ProcessedEvent.record`).

Os erros `invalid_payload` e `not_found` não ficam em `processed_events`: uma ação corrigida com a mesma chave ainda pode ser aceita.

**Concorrência.** A trava na linha da conversa serializa as ações da mesma conversa. Duas ações com a mesma chave, enviadas ao mesmo tempo, chegam ao passo 3 juntas; a segunda espera o commit da primeira. No nível de isolamento `READ COMMITTED`, padrão do PostgreSQL, cada comando lê o que já foi confirmado no início dele: a consulta a `processed_events` da segunda transação, feita depois da trava, encontra a linha gravada pela primeira e devolve o mesmo corpo. Se `ProcessedEvent.record` encontrasse a chave já gravada, a exceção desfaria a transação inteira, sem efeito.

**Por que o estado antes da sequência.** A conversa pode mudar de estado sem mensagem nova do lojista (analista assume, `resolve` aceito), e com o estado fora de `with_ai` nenhuma ação do agente vale, atual ou não.

### Evento da ação

Cada ação aceita grava um evento próprio, `agent.<type>`, por `Audit::Command`:

| Campo | Conteúdo |
| - | - |
| `actor_type`, `actor_id` | `ai` e o atendente da conversa |
| `target` | A mensagem gravada no `reply`; a conversa nas demais |
| envelope `sequence` | A sequência da mensagem do `reply`; nulo nas demais |
| envelope `received_at` | Horário em que o Core recebeu a chamada do Broker (`TraceContextMiddleware`) |
| envelope `traceparent`, `trace_id` | O trace do header `traceparent` da chamada |
| `payload` | `idempotency_key` e `action`, o corpo completo da ação: ferramentas com entradas, saídas e horários, `model` quando existe e os carimbos `broker_received_at`, `kafka_appended_at`, `agent_consumed_at` e `agent_published_at` |

Os eventos de domínio da ação (`message.created`, `conversation.escalated`, `conversation.classified`, `conversation.routed`, `conversation.resolved`) são gravados à parte, na mesma transação. O `event_id` da resposta `accepted` é o do evento da ação.

As recusas gravam `agent.action.stale` (payload com a ação, a chave, `based_on_sequence` e `last_customer_sequence`) e `agent.action.rejected` (payload com a ação, a chave e `state`), com a conversa como alvo. Na recusa por estado, o atendente da conversa pode ser um analista ou nenhum; o ator é o atendente IA da marca (`Attendant.first_ai`), porque quem tentou agir foi a IA.

### Ações

| Ação | Efeito | `message_sequence` |
| - | - | - |
| `reply` | Grava a mensagem com autor `ai` e o atendente da conversa por `Conversations::Outbound.append!`, que enfileira `Channels::DeliveryJob` na mesma transação | Sequência da mensagem gravada |
| `escalate` | Grava o `Handoff` (`reason`, `summary`, `context` da ação) e `conversation.escalated`; a conversa vai de `with_ai` a `awaiting_human` na fila atual, sem atendente e com `queued_at` | Nulo |
| `categorize` | Chama `Routing::Route` com `trigger: "categorize"`, a categoria e o atendente IA como `actor_id`. A conversa volta a `with_ai`, vai para fila humana ou fica em `triage`. O webhook não é reenviado | Nulo |
| `resolve` | `with_ai → resolved` (`conversation.resolved`, com o `reason` da ação quando existe), grava `resolved_at` e mantém o atendente. Nenhuma mensagem vai ao lojista | Nulo |

**`in_reply_to_sequence` do `reply`.** É a última mensagem do lojista com `sequence` menor ou igual ao `based_on_sequence`. A entrega (`Channels::DeliveryJob`) lê o destinatário (`identity`) do `message.created` da mensagem respondida, e esse campo existe só em mensagem do lojista. Como a ação aceita não está desatualizada, a mensagem respondida é a última do lojista na conversa.

**Uma ação de cada tipo por evento.** A `Idempotency-Key` é `<inbound_event_id>:<type>`: o agente pode enviar `categorize` e `reply` para o mesmo evento. Se o `categorize` leva a conversa para fila humana ou a deixa em `triage`, o `reply` seguinte recebe `409 rejected`.

## Task `agent:`

Prova da API sem o Broker, rodada no contêiner `web`:

```text
bin/rails agent:context CONVERSATION=<id>
bin/rails agent:action CONVERSATION=<id> TYPE=reply TEXT="..."
bin/rails agent:action CONVERSATION=<id> TYPE=categorize CATEGORY=maquininha
bin/rails agent:action CONVERSATION=<id> TYPE=escalate [REASON=...] [SUMMARY=...]
bin/rails agent:action CONVERSATION=<id> TYPE=resolve [REASON=...]
```

- A ação nasce do `message.created` da última mensagem do lojista: `inbound_event_id` e `based_on_sequence` vêm dele; `INBOUND_EVENT_ID` e `BASED_ON` os substituem.
- Carimbos e `traceparent` são gerados na hora; a lista de ferramentas é vazia. A ação é validada pelo schema `action` antes do envio.
- O endereço do Core é `CORE_URL`, com padrão `http://localhost:3000`, o próprio `web`.
- A mesma ação enviada de novo tem a mesma `Idempotency-Key` e recebe o resultado da primeira.

## Testes

| Arquivo | Cobertura |
| - | - |
| `spec/modules/agents/action_processor_spec.rb` | Cada tipo de ação e seus eventos; ação duplicada com um único efeito; duplicadas simultâneas, em threads com commit; `stale` e `rejected` com `audit_event` e repetição sem novo evento; `stale` nas quatro ações; estado conferido antes da sequência; conferências do `422`; `404`; corpo, ferramentas, `model` e carimbos no evento da ação; `in_reply_to_sequence`; transições e campos de `escalate`, `categorize` e `resolve` |
| `spec/modules/agents/conversation_context_spec.rb` | Corpo segue o schema `context`; ordem das mensagens; isolamento por marca |
| `spec/requests/api/v1/agent/actions_spec.rb` | `200` e repetição; `trace_id` do header `traceparent`; `409 stale` e `409 rejected`; assinatura inválida, com o segredo do contexto e vencida; sem `Idempotency-Key`; corpo inválido; marca inexistente e conversa de outra marca; corpos validados pelo schema `action-response` |
| `spec/requests/api/v1/agent/contexts_spec.rb` | Assinatura com `AGENT_CONTEXT_SECRET`; query string assinada; recusa com o segredo das ações; timestamp vencido; marca no caminho assinado; `404` para conversa de outra marca, marca inexistente e id que não é UUID; corpo validado pelo schema `context` |
| `spec/contract/message_created_spec.rb` | `context_url` com a marca |

O `contract/schemas_spec.rb`, o `contract/signature_spec.rb`, o `agent_mock/tests/contract/test_contract.py` e o `channel_simulator/tests/test_signature.py` leem os exemplos e vetores sem mudança de código.

Resultado: suíte completa do RSpec com 592 exemplos sem falha; `pytest` do `agent_mock` com 78 testes e do simulador (`test_signature.py`) com 7, sem falha.

## Pronto quando

- A mesma ação enviada duas vezes produz um único efeito e a segunda recebe o corpo da primeira: `action_processor_spec.rb`, `actions_spec.rb` e a prova no Compose.
- Uma ação com `based_on_sequence` desatualizado recebe `409 stale` e gera `audit_event`: idem.
- Uma ação com a conversa fora de `with_ai` recebe `409 rejected` e gera `audit_event`: idem.
- Um `reply` chega ao canal de origem: prova no Compose, com a resposta registrada pelo simulador.
- O `audit_event` da ação guarda as ferramentas e os carimbos de cada salto: `action_processor_spec.rb`.
- O `GET` assinado da `context_url` devolve o histórico conforme o schema `context`: `contexts_spec.rb` e a prova no Compose.
- Os testes de contrato em RSpec e em pytest passam com os exemplos novos.

### Prova no Compose

Com `web`, `jobs-default`, `jobs-webhooks` e `channel-simulator` no ar e sem o Broker:

1. `send` do simulador com uma mensagem de WhatsApp de lojista novo da InfinitePay: conversa em `with_ai`, sequência 1.
2. `agent:context`: `200` com a conversa e a mensagem do lojista, `customer_memory` nulo.
3. `agent:action TYPE=reply`: `200 accepted`, `message_sequence` 2; a resposta chega ao `received.jsonl` do simulador pelo mesmo número da marca, com o id da mensagem do Core.
4. O mesmo `reply` de novo: `200` com o mesmo corpo (o `jsonb` devolve as chaves em outra ordem) e uma única mensagem da IA.
5. Nova mensagem do lojista (sequência 3) e `agent:action TYPE=resolve BASED_ON=1` com o evento da sequência 1: `409 stale`, `last_customer_sequence` 3.
6. `agent:action TYPE=resolve`: `200 accepted`; a conversa vai a `resolved`. `agent:action TYPE=reply` em seguida: `409 rejected`, `state` `resolved`.
7. Em outra conversa, levada a `awaiting_human` por um `escalate`, uma ação recebe `409 rejected`, `state` `awaiting_human`.
8. Os `audit_events` das conversas mostram, em ordem: `message.created` da IA e `agent.reply`, com a chave e o corpo da ação; `message.delivered`; `agent.action.stale`; `conversation.resolved` e `agent.resolve`; `conversation.escalated` e `agent.escalate`; `agent.action.rejected` com o motivo `conversa em <estado>`. A repetição do passo 4 não grava evento.

## Pontos de atenção

- **Trava na conversa.** O `FOR UPDATE` serializa as ações da mesma conversa e também as mensagens de entrada, que atualizam `last_sequence` na mesma linha. A F15 mede o efeito na carga.
- **Volume no `web`.** Cada mensagem de entrada gera, no `web`, o `GET` de contexto e o `POST` da ação; a 250 msg/s são cerca de 500 req/s a mais. O contexto sem cache é medido na F15.
- **Ordem entre ações do mesmo evento.** A ordem entre `categorize` e `reply` do mesmo evento vem da partição de `agent.outbound`.
- **Conversa escalada.** Até a F11, a conversa escalada fica em `awaiting_human` na fila da IA, que não tem equipe; o `Routing::Distributor` não a entrega a analista.
- **Outros `4xx`.** As respostas `4xx` que não são `409` vão para a DLQ no Broker (F9).
- **Ordem das chaves na repetição.** O corpo guardado em `processed_events.result` é `jsonb`, que não preserva a ordem das chaves: a repetição devolve o mesmo conteúdo com as chaves em outra ordem.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F9 | O `broker-consumer` chama a API de ações | `POST /api/v1/agent/actions` com `AGENT_ACTIONS_SECRET`, `Idempotency-Key` e `traceparent`; `409 stale` e `409 rejected` são resultado final; os demais `4xx` vão para a DLQ |
| F10 | O agente lê a `context_url` | `GET` assinado com `AGENT_CONTEXT_SECRET` sobre o caminho com a marca |
| F11 | O `escalate` leva a conversa a `awaiting_human` na fila atual | A F11 acrescenta o roteamento para a fila humana pela regra de escalação, a notificação e o painel |
| F12 | `customer_memory` é nulo | A F12 preenche a memória do lojista no `Agents::ConversationContext` |
| F14 | O evento da ação guarda os carimbos de cada salto | A linha do tempo por mensagem lê `agent.<type>` e o `trace_id` |
| F15 | Contexto sem cache e trava por conversa | Medidas na carga; cache no Solid Cache se a medida pedir |

## Fontes

- `contexto/plano-f8-api-de-acoes-e-contexto.md`, decisões aprovadas
- `documents/arquitetura.md`, seções "Contrato com o agente", "Idempotência", "Ação sobre contexto desatualizado", "Ação com a conversa fora da IA" e "Auditoria e rastreabilidade"
- `documents/fases/04-contrato-de-integracao.md`, seções "Resposta da API de ações", "Contexto da conversa" e "Assinatura"
- `documents/fases/05-canais-de-entrada-e-identidade.md`, seção da saída por `Conversations::Outbound.append!`
- `documents/fases/07-triagem-roteamento-e-distribuicao.md`, ponto de entrada `categorize` do `Routing::Route`
- [PostgreSQL 18 · Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html)
- [PostgreSQL 18 · Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html)

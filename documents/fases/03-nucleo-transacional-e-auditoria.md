# Cloudesk · F2 · Núcleo transacional e auditoria

## Objetivo

A F2 entrega o caminho único pelo qual toda decisão do sistema é gravada: o envelope canônico de evento, o serviço de comando e o contexto de trace. Canais (F4), roteamento (F6), ações do agente (F8) e handoff (F11) gravam por esse caminho.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Ponto único de escrita | `Audit::Command`, em `core/app/modules/audit/command.rb` |
| Transação | Uma só, aberta por `Tenancy.with_brand`: mudança de estado, `audit_event` e job de webhook |
| Envelope | `Audit::EventEnvelope`, gravado inteiro em `audit_events.payload` |
| `event_id` | UUID v7 gerado no Core; o mesmo valor na coluna `audit_events.event_id` e no envelope |
| Job de webhook | `Agents::WebhookDeliveryJob`, fila `webhooks`, com `brand_id`, `event_id` e `traceparent` nos argumentos |
| Enfileiramento | Dentro da transação; `enqueue_after_transaction_commit` desligado |
| Contexto de trace | `traceparent` W3C lido por middleware Rack e mantido em `Current` |
| Horário de recebimento | `received_at`, carimbado pelo mesmo middleware |
| Migrações | Nenhuma: as colunas de `audit_events` vêm da F1 |

## Arquivos

| Arquivo | Conteúdo |
| - | - |
| `core/lib/trace_context.rb` | Leitura, geração e continuação do `traceparent` |
| `core/lib/middleware/trace_context_middleware.rb` | Middleware Rack: trace e `received_at` de cada requisição |
| `core/app/models/current.rb` | `Current.traceparent` e `Current.received_at` |
| `core/app/modules/audit/event_envelope.rb` | Envelope canônico |
| `core/app/modules/audit/command.rb` | Serviço de comando |
| `core/app/modules/agents/webhook_delivery_job.rb` | Job da fila `webhooks` |
| `core/spec/lib/`, `core/spec/modules/` | Testes |

## Envelope canônico

O envelope é o formato único de todo evento do Core, qualquer que seja a origem.

| Campo | Conteúdo |
| - | - |
| `event_id` | UUID v7 do evento |
| `type` | Tipo do evento, por exemplo `message.created`; é também o valor de `audit_events.action` |
| `brand` | Slug da marca |
| `conversation_id` | Conversa do evento, ou nulo quando o evento não pertence a uma conversa |
| `sequence` | Sequência da mensagem na conversa, ou nulo quando o evento não é de mensagem |
| `received_at` | Horário em que o Core recebeu a requisição que produziu o evento; ISO 8601, UTC, com milissegundos |
| `payload` | Conteúdo completo do evento, específico do tipo |
| `traceparent` | Contexto de trace W3C do salto que produziu o evento |

- O envelope é um objeto imutável (`Data`), sem acesso ao banco. `to_h` produz a forma em JSON e `from_h` a lê de volta.
- O envelope inteiro é gravado em `audit_events.payload`. O job de webhook lê o evento dessa coluna; o `audit_event` é a única cópia do evento.
- O `event_id` é gerado no Core com `SecureRandom.uuid_v7`, porque o valor entra no envelope antes do `INSERT`. A coluna `audit_events.event_id` recebe o mesmo valor e mantém o default `uuidv7()` do banco.
- O corpo do webhook `message.created` é montado a partir do envelope, pelo contrato da F3 (`documents/fases/04-contrato-de-integracao.md`).

**Embasamento.**

- O Ruby 3.4 da imagem do Core oferece `SecureRandom.uuid_v7` (`Random::Formatter#uuid_v7`). Um teste afirma que o `event_id` gerado tem o formato de UUID versão 7.
- `messages` não tem `event_id` (`documents/fases/02-banco-multi-marca-e-entidades.md`); o identificador do evento é o do `audit_event`.

## Serviço de comando

```ruby
Audit::Command.call(brand: brand, type: "message.created", actor_type: "customer", webhook: true) do |change|
  message = conversation.append_message!(channel: "whatsapp", author: "customer", body: "oi")
  change.target = message
  change.conversation = conversation
  change.sequence = message.sequence
  change.payload = { message: { author: "customer", channel: "whatsapp", text: "oi" } }
  message
end
```

Argumentos do comando:

| Argumento | Conteúdo |
| - | - |
| `brand` | `Brand` da transação |
| `type` | Tipo do evento |
| `actor_type`, `actor_id` | Quem decidiu: `customer`, `ai`, `analyst`, `operator` ou `system`, e o id quando o ator é um registro |
| `reason` | Motivo da decisão |
| `routing_rule` | Versão da `RoutingRule` que casou; o comando grava `routing_rule_id` e `rule_version` |
| `webhook` | `true` quando o evento sai para o Broker |

O bloco executa a mudança de estado e informa, em `change`, o alvo, a conversa, a sequência, o antes, o depois e o payload. O bloco também pode informar `change.routing_rule`, que vale no lugar do argumento `routing_rule`: é o caso da versão de regra gravada pelo próprio bloco, no `Routing::RulePublisher`. O comando devolve o retorno do bloco, o `audit_event` e o envelope.

Passos, todos dentro de um único `Tenancy.with_brand`:

1. executa o bloco;
2. recusa o comando que não informa o alvo;
3. monta o envelope com o `traceparent` e o `received_at` correntes;
4. grava o `audit_event`: ator, ação, alvo, conversa, antes e depois, envelope, motivo, regra e versão, `trace_id`;
5. enfileira o `Agents::WebhookDeliveryJob`, quando `webhook` é `true`.

Um erro em qualquer passo desfaz todos os anteriores.

### Outbox implícito

- O Solid Queue grava o job pela mesma conexão do app (`SolidQueue::Record.connection_pool` é o pool do `ApplicationRecord`). O `INSERT` do job participa da transação do comando.
- Se a transação falha, não existe mudança de estado, `audit_event` nem job. Se ela confirma, os três existem.
- `enqueue_after_transaction_commit` fica desligado: com ele ligado, o job é gravado depois do commit, fora da transação, e um processo que cai entre o commit e a gravação perde o job.

**Embasamento.**

- No código do Active Job 8.1.4.1, `ActiveJob::Enqueuing` declara `class_attribute :enqueue_after_transaction_commit, ..., default: false`. O `Agents::WebhookDeliveryJob` declara o valor `false` na própria classe, e um teste o afirma.
- O README do Solid Queue documenta a configuração de banco único para o app e a fila; a F0 a aplica (`documents/fases/01-repositorio-e-infraestrutura-local.md`).

### Job de webhook

- Fila `webhooks`.
- Argumentos: `brand_id`, `event_id` e `traceparent`. As tabelas do Solid Queue ficam fora do RLS, e o worker define a marca a partir dos argumentos.
- Ao executar, o job continua o trace e lê o envelope em `audit_events`, dentro de `Tenancy.with_brand`.
- O envio HTTP assinado ao Broker é entrega da F7. Na F2, o método de envio lança `NotImplementedError`: um job executado vai para a fila de falhas do Solid Queue e fica disponível para reprocessamento.

## Contexto de trace

O `traceparent` segue o formato do W3C Trace Context:

```text
00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
versão - trace_id (32 hex) - parent_id (16 hex) - flags (2 hex)
```

- O `trace_id` identifica o caminho inteiro de uma mensagem. O `parent_id` identifica o salto que produziu o header.
- O `TraceContextMiddleware` lê o header `traceparent` de cada requisição HTTP. Com header válido, o Core mantém o `trace_id` e gera um `parent_id` próprio. Sem header, ou com header inválido, o Core inicia um trace.
- Só a versão `00` é aceita; `trace_id` e `parent_id` zerados são inválidos.
- O mesmo middleware carimba o `received_at`, o horário de recebimento da requisição. É o ponto inicial das medidas das hipóteses H2 e H4.
- Os dois valores ficam em `Current`, que o Rails limpa antes e depois de cada requisição. O middleware fica depois de `ActionDispatch::Executor` e de `ActionDispatch::Callbacks` na pilha. Em desenvolvimento, `ActionDispatch::Callbacks` vem depois do `ActionDispatch::Reloader`: o recarregamento de código troca a classe `Current`, e um valor gravado antes dele se perderia.
- O serviço de comando grava o `trace_id` na coluna `audit_events.trace_id`, o `traceparent` no envelope e nos argumentos do job. Fora de uma requisição HTTP, o comando inicia um trace.
- Não há gem de tracing: OpenTelemetry está na seção "Evolução" da arquitetura.

**Embasamento.**

- A recomendação W3C Trace Context define o header com `trace-id` de 32 caracteres hexadecimais e `parent-id` de 16. Sobre o valor com todos os bytes em zero, nos dois campos: "is considered an invalid value". Sobre o campo inválido: "vendors MUST ignore the traceparent"; no modelo de processamento, o receptor cria um `traceparent` novo.
- O guia de autoloading do Rails traz o padrão `config.autoload_lib(ignore: %w(assets tasks ... middleware))` e registra que não há sentido em definir um middleware Rack recarregável, porque a mudança não chega à instância guardada na pilha de middlewares. O arquivo é carregado por `require` em `config/application.rb`.
- A documentação de `ActiveSupport::CurrentAttributes` a descreve como "a thread-isolated attributes singleton, which resets automatically before and after each request". Um teste afirma que, depois de uma requisição pela pilha completa do app, `Current` está vazio.

## Testes

Os testes rodam com o papel da aplicação, dentro da transação do RSpec.

- `audit_events` não aceita `DELETE`, nem do papel dono, e as chaves estrangeiras não têm `ON DELETE`. Um teste com commit de verdade deixaria linhas permanentes no banco de teste.
- O serviço de comando abre um savepoint em `Tenancy.with_brand`. O erro desfaz o savepoint, como o rollback desfaz a transação; o sucesso mantém as três gravações. O PostgreSQL documenta que o `ROLLBACK TO SAVEPOINT` desfaz todos os comandos executados depois do savepoint.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`, provado em `core/spec/modules/audit/command_spec.rb`:

- com erro no bloco, na gravação do `audit_event` ou no enfileiramento, não existe mudança de estado, `audit_event` nem job;
- com sucesso, estado, `audit_event` e job existem juntos, e o job está na fila `webhooks`;
- `enqueue_after_transaction_commit` está desligado;
- o `traceparent` da requisição aparece no `audit_event` e nos argumentos do job.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F4, F6, F8, F11 | Toda escrita de domínio passa por `Audit::Command` | Cada fase chama o comando com o tipo do evento e o bloco da mudança |
| F7 | O `Agents::WebhookDeliveryJob` lê o envelope e não envia | A F7 entrega o envio HTTP assinado, os retries e o processo `jobs-webhooks` |
| F14 | `received_at` e `trace_id` ficam em `audit_events` | A linha do tempo por mensagem parte desses dois valores |

## Fontes

- [W3C - Trace Context](https://www.w3.org/TR/trace-context/)
- [Rails Guides - Autoloading and Reloading Constants](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [Rails API - ActiveSupport::CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
- [Rails API - ActiveJob::Enqueuing](https://api.rubyonrails.org/classes/ActiveJob/Enqueuing.html)
- [Ruby - Random::Formatter](https://docs.ruby-lang.org/en/3.4/Random/Formatter.html)
- [PostgreSQL 18 - ROLLBACK TO SAVEPOINT](https://www.postgresql.org/docs/current/sql-rollback-to.html)
- [Solid Queue README](https://github.com/rails/solid_queue)

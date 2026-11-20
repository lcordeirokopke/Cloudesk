# Cloudesk · Núcleo transacional e auditoria

## O que é

O núcleo transacional e de auditoria é o caminho único pelo qual toda decisão do Cloudesk é gravada. Ele reúne três peças:

- **o serviço de comando** (`Audit::Command`): executa uma mudança de estado, grava o registro de auditoria dela e, quando o evento sai para o Broker, enfileira o webhook, tudo na mesma transação;
- **o envelope canônico de evento** (`Audit::EventEnvelope`): o formato único de todo evento do Core, gravado inteiro na auditoria;
- **o contexto de trace** (`TraceContext` e `TraceContextMiddleware`): o `traceparent` W3C e o horário de recebimento de cada requisição, que acompanham o evento de ponta a ponta.

Canais, roteamento, ações do agente, distribuição, gravação de regras e entregas passam todos por esse caminho. Não existe escrita de domínio fora dele.

## Onde fica no fluxo

```text
requisição HTTP ── TraceContextMiddleware ── Current.traceparent, Current.received_at
                                                   │
       Intake, Route, ActionProcessor, Distributor, RulePublisher, DeliveryJob, ...
                                                   │
                                   Audit::Command (uma transação, na marca)
                                    ├─ bloco: mudança de estado
                                    ├─ envelope canônico
                                    ├─ audit_event (append-only)
                                    └─ Agents::WebhookDeliveryJob (quando o evento sai para o Broker)
```

## Por que existe e que valor gera

**Toda decisão é auditada.** O princípio do projeto é que cada decisão gera um registro com o payload completo, quem decidiu, o motivo e a regra e a versão que a produziram. Com um caminho único de escrita, isso não depende da disciplina de cada parte do código: quem muda o estado grava a auditoria, sem exceção.

**Nenhuma mensagem perdida na saída.** A mudança de estado, o registro de auditoria e o job de webhook são gravados na mesma transação do PostgreSQL. Se a transação confirma, os três existem; se falha, nenhum existe. Não há janela em que a mensagem foi aceita e o aviso ao agente ficou só na memória de um processo. Esse outbox implícito é a base da hipótese H3.

**Uma fonte só para o evento.** O `audit_event` guarda o envelope completo, e o webhook ao Broker é montado a partir dele. Não existe uma cópia do evento na fila e outra na auditoria que possam divergir; o `event_id` do webhook é o do `audit_event`.

**Linha do tempo por mensagem.** Cada evento grava o `trace_id` e o horário de recebimento da requisição. Com o mesmo `trace_id` propagado por HTTP e Kafka, a linha do tempo de uma mensagem, da entrada à resposta, é montada só a partir de `audit_events`.

**Auditoria imutável.** `audit_events` é append-only: `UPDATE`, `DELETE` e `TRUNCATE` são bloqueados por permissão e por trigger no banco. O registro de uma decisão não pode ser alterado nem pela aplicação.

## Como funciona

### Serviço de comando

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

| Argumento | Conteúdo |
| - | - |
| `brand` | `Brand` da transação |
| `type` | Tipo do evento, gravado em `audit_events.action` e no envelope |
| `actor_type`, `actor_id` | Quem decidiu (`customer`, `ai`, `analyst`, `operator` ou `system`) e o id quando o ator é um registro |
| `reason` | Motivo da decisão |
| `routing_rule` | Versão da `RoutingRule` que casou; o comando grava a regra e a versão |
| `webhook` | `true` quando o evento sai para o Broker |

O bloco executa a mudança e informa, em `change`, o alvo, a conversa, a sequência, o estado antes e depois e o payload. O bloco também pode informar `change.routing_rule`, que vale no lugar do argumento: é o caso da versão de regra gravada pelo próprio bloco. O comando devolve o retorno do bloco, o `audit_event` e o envelope.

Todos os passos rodam em um único `Tenancy.with_brand`, na marca do comando:

1. executa o bloco;
2. recusa o comando que não informa o alvo da mudança;
3. monta o envelope com o `traceparent` e o `received_at` correntes;
4. grava o `audit_event`: ator, ação, alvo, conversa, antes e depois, envelope, motivo, regra e versão e `trace_id`;
5. enfileira o `Agents::WebhookDeliveryJob`, quando `webhook` é `true`.

Um erro em qualquer passo desfaz todos os anteriores. Um comando chamado dentro de outro (por exemplo, o roteamento dentro do Intake) participa da mesma transação.

### Outbox implícito

- O Solid Queue usa o mesmo banco do app e grava o job pela mesma conexão (`SolidQueue::Record.connection_pool` é o pool do `ApplicationRecord`). O `INSERT` do job participa da transação do comando.
- `enqueue_after_transaction_commit` fica desligado nos jobs de saída (`Agents::WebhookDeliveryJob` e `Channels::DeliveryJob`): com ele ligado, o job seria gravado depois do commit, fora da transação, e um processo que caísse entre o commit e a gravação perderia o job.
- O job leva nos argumentos `brand_id`, `event_id` e `traceparent`. As tabelas do Solid Queue ficam fora do RLS, e o worker define a marca a partir dos argumentos; o envelope é lido de `audit_events`.

### Envelope canônico

| Campo | Conteúdo |
| - | - |
| `event_id` | UUID v7 do evento |
| `type` | Tipo do evento, por exemplo `message.created` |
| `brand` | Slug da marca |
| `conversation_id` | Conversa do evento, ou nulo quando o evento não pertence a uma conversa |
| `sequence` | Sequência da mensagem na conversa, ou nulo quando o evento não é de mensagem |
| `received_at` | Horário em que o Core recebeu a requisição que produziu o evento; ISO 8601, UTC, com milissegundos |
| `payload` | Conteúdo completo do evento, específico do tipo |
| `traceparent` | Contexto de trace W3C do salto que produziu o evento |

- O envelope é um objeto imutável (`Data`), sem acesso ao banco; `to_h` produz a forma JSON e `from_h` a lê de volta.
- O `event_id` é gerado no Core com `SecureRandom.uuid_v7`, porque entra no envelope antes do `INSERT`; a coluna `audit_events.event_id` recebe o mesmo valor.
- O corpo do webhook `message.created` é montado a partir do envelope, pelo contrato (`documents/fases/04-contrato-de-integracao.md`).

### Contexto de trace

```text
00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
versão - trace_id (32 hex) - parent_id (16 hex) - flags (2 hex)
```

- O `trace_id` identifica o caminho inteiro de uma mensagem; o `parent_id` identifica o salto que produziu o header.
- O `TraceContextMiddleware` lê o `traceparent` de cada requisição HTTP. Com header válido, o Core mantém o `trace_id` e gera um `parent_id` próprio; sem header, ou com header inválido, inicia um trace. Só a versão `00` é aceita, e `trace_id` ou `parent_id` zerados são inválidos, como define o W3C.
- O mesmo middleware carimba o `received_at`, o horário de recebimento da requisição. É o ponto inicial das medidas das hipóteses H2 e H4.
- Os dois valores ficam em `Current`, que o Rails limpa antes e depois de cada requisição. O middleware fica depois de `ActionDispatch::Callbacks` na pilha: em desenvolvimento, o recarregamento de código troca a classe `Current`, e um valor gravado antes dele se perderia.
- Os jobs continuam o trace recebido nos argumentos (`TraceContext.continue`), e o comando chamado fora de uma requisição HTTP inicia um trace.
- O comando grava o `trace_id` em `audit_events.trace_id` e o `traceparent` no envelope e nos argumentos do job.

## O que o sistema garante

- Toda mudança de estado de domínio tem um `audit_event`, gravado na mesma transação.
- Mudança, `audit_event` e job de webhook existem juntos ou não existem.
- O `event_id` do webhook é o do `audit_event`, e o envelope tem uma única cópia.
- Todo `audit_event` tem o ator, o `trace_id` e o horário de recebimento, e o de roteamento tem a regra e a versão.
- Nenhum `audit_event` é alterado ou apagado depois de gravado.
- Toda escrita acontece dentro da marca do comando.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Rastreabilidade e auditoria das decisões, com linha do tempo por mensagem a partir de `audit_events` e `trace_id` | O registro de toda decisão, com ator, motivo, regra, versão, payload completo, `trace_id` e `received_at` | Tabela append-only e RLS (F1); carimbos dos outros saltos (F3 e F8); linha do tempo na tela (F14) |
| Integração com o atendente por webhooks e broker | O job de webhook gravado na transação da mensagem, com o envelope que vira o corpo do webhook | Envio (F7) e Broker (F9) |
| Triagem, handoff e ações do agente auditados | O caminho comum pelo qual o roteamento, as ações do agente e a distribuição gravam as suas decisões | Cada decisão na sua parte (F4, F6, F8 e F11) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H3 · nada perdido nem duplicado | O outbox implícito garante que toda mensagem aceita com a conversa na IA tem o job de webhook persistido; uma queda depois do commit não perde o aviso |
| H2 e H4 · latência | O `received_at` carimbado na entrada é o início das duas medidas, e o `trace_id` liga os carimbos de todos os saltos |
| H1 · 250 msg/s | Cada mensagem custa uma transação com a mudança, um ou mais `audit_events` e o job; o volume de gravações por mensagem é uma das medidas do experimento |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 4 · "Por que caiu aqui?" | O comando grava a regra e a versão no `audit_event` de roteamento, que é a fonte da explicação |
| 3 · Disjuntor de IA | O acionamento do disjuntor deve gerar `audit_event` com autor e motivo; o comando oferece o ator e o motivo para isso |
| 1 · Briefing de handoff | O `audit_event` da ação guarda o corpo completo do `escalate`, com o briefing |

## Limitações

- **Volume de `audit_events`.** Cada decisão gera uma linha, e uma mensagem gera várias (classificação, roteamento, mensagem, ação, entrega). A tabela é única, sem particionamento; o crescimento contínuo exige particionar.
- **Envelope dentro da auditoria.** O job lê o envelope em `audit_events`, e não leva uma cópia: a leitura acontece a cada tentativa de envio.
- **Trace sem ferramenta de tracing.** O `traceparent` é propagado e gravado, mas não existe coletor de tracing distribuído; a linha do tempo é montada da auditoria.
- **Relógios.** A linha do tempo compara horários de processos diferentes e depende de os relógios estarem alinhados; no ambiente local, todos usam o relógio da mesma máquina.
- **Testes sem commit.** `audit_events` não aceita `DELETE`, e as chaves estrangeiras não têm `ON DELETE`: os testes rodam dentro da transação do RSpec, e o comando abre um savepoint em `Tenancy.with_brand`, desfeito no erro. Os poucos testes que precisam de commit de verdade limpam o banco com o papel dono, desligando o trigger só durante a limpeza.

## Operação

### Arquivos principais

| Arquivo | Conteúdo |
| - | - |
| `core/app/modules/audit/command.rb` | Serviço de comando |
| `core/app/modules/audit/event_envelope.rb` | Envelope canônico |
| `core/lib/trace_context.rb` | Leitura, geração e continuação do `traceparent` |
| `core/lib/middleware/trace_context_middleware.rb` | Trace e `received_at` de cada requisição; carregado por `require` em `config/application.rb`, fora do autoload, porque um middleware Rack recarregável não alcança a instância guardada na pilha |
| `core/app/models/current.rb` | `Current.traceparent` e `Current.received_at` |

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/audit/command_spec.rb` | Com erro no bloco, na gravação do `audit_event` ou no enfileiramento, não existe mudança, `audit_event` nem job; com sucesso, os três existem e o job está na fila `webhooks`; `enqueue_after_transaction_commit` desligado; o `traceparent` da requisição no `audit_event` e nos argumentos do job |
| `core/spec/modules/audit/event_envelope_spec.rb` | Forma do envelope, `event_id` UUID v7 e leitura de volta |
| `core/spec/lib/trace_context_spec.rb` | Leitura, recusa de header inválido, geração e continuação do trace |
| `core/spec/lib/trace_context_middleware_spec.rb` | Trace continuado ou iniciado e `received_at` em `Current` durante a requisição; posição na pilha do app; nenhum contexto de uma requisição passa para a seguinte |

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco multi-marca (F1) | `Tenancy.with_brand`, a tabela `audit_events` append-only e as colunas de ator, regra, versão e `trace_id` |
| Contrato (F3) | O webhook é montado a partir do envelope |
| Canais (F4) | O Intake, o Outbound e a entrega gravam pelo comando |
| Roteamento (F6) | Classificação, roteamento, atribuição e publicação de regra gravam pelo comando, com a regra e a versão |
| Saída para o Broker (F7) | O `Agents::WebhookDeliveryJob` lê o envelope e envia |
| API de ações (F8) | Cada ação e cada recusa gravam pelo comando |
| Observabilidade (F14) | A linha do tempo por mensagem parte de `received_at` e `trace_id` |

## Fontes

- `documents/arquitetura.md`, seções "Decisões de design" e "Auditoria e rastreabilidade"
- [W3C · Trace Context](https://www.w3.org/TR/trace-context/)
- [Rails Guides · Autoloading and Reloading Constants](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [Rails API · ActiveSupport::CurrentAttributes](https://api.rubyonrails.org/classes/ActiveSupport/CurrentAttributes.html)
- [Rails API · ActiveJob::Enqueuing](https://api.rubyonrails.org/classes/ActiveJob/Enqueuing.html)
- [Ruby · Random::Formatter](https://docs.ruby-lang.org/en/3.4/Random/Formatter.html)
- [PostgreSQL 18 · ROLLBACK TO SAVEPOINT](https://www.postgresql.org/docs/current/sql-rollback-to.html)
- [Solid Queue · README](https://github.com/rails/solid_queue)

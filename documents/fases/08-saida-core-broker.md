# Cloudesk · F7 · Saída Core → Broker

## Objetivo

A F7 entrega os webhooks do Core ao Broker sem perda. O `Agents::WebhookDeliveryJob`, na fila `webhooks`, envia o `message.created` assinado conforme o contrato da F3, com retries com backoff exponencial e jitter; ao esgotar as tentativas, o job fica na fila de falhas do Solid Queue e é reprocessado pelo painel do Mission Control - Jobs. O processo `jobs-webhooks` atende só a fila `webhooks`, e o `jobs-default` atende as demais.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Endereço do Broker | `BROKER_WEBHOOK_URL`, com valor `http://broker-web:3000/webhooks/message-created`. O caminho assinado é o caminho da URI, com a query string |
| Segredo | `BROKER_WEBHOOK_SECRET`, no `.env` e no bloco `x-rails` do Compose; o `broker-web` usa a mesma variável |
| Cliente HTTP | Net::HTTP, com conexão nova por envio. Timeout de conexão de 2 s e de leitura de 5 s |
| Requisição | `POST` com `Content-Type: application/json`. O corpo é serializado uma vez e a assinatura é feita sobre os mesmos bytes. Headers `X-Cloudesk-Timestamp`, `X-Cloudesk-Signature` e `traceparent`. Cada tentativa gera timestamp e assinatura próprios |
| Resposta | 2xx é sucesso. 408, 429, 5xx e erro de rede, inclusive de DNS, são transitórios e têm retry. Os demais status (1xx, 3xx e os outros 4xx) são permanentes e vão direto para a fila de falhas. Evento que não é `message.created` ou corpo fora do schema também são permanentes |
| Retry | `retry_on` com 10 tentativas e `ApplicationJob::EXPONENTIAL_BACKOFF`: `2^n` segundos mais até 15%, cerca de 17 minutos até a fila de falhas. A mesma lambda serve `Channels::DeliveryJob`, `Channels::Email::IngestJob` e `Agents::WebhookDeliveryJob` |
| Estado da conversa | Antes de enviar, o job confere o estado da conversa. Fora de `with_ai`, grava `webhook.skipped` e não chama o Broker |
| Auditoria da entrega | A resposta 2xx não grava `audit_event`. A linha do tempo recebe `broker_received_at` e `kafka_appended_at` pelo `audit_event` da ação do agente, e as tentativas ficam visíveis no painel |
| Processos | `jobs-webhooks`: worker de `webhooks` com 5 threads e polling de 0,1 s, dispatcher próprio e sem tarefas recorrentes. `jobs-default`: worker de `channels` com polling de 0,1 s e worker de `default` e das filas do Action Mailbox com 1 s, dispatcher e tarefas recorrentes |
| Pool | O worker de 5 threads usa 7 conexões; o serviço `jobs-webhooks` define `RAILS_MAX_THREADS=7`. O `config/database.yml` não muda |
| Painel | Mission Control - Jobs 1.3.1 montado em `/jobs` no `web`, com HTTP basic auth por `MISSION_CONTROL_USER` e `MISSION_CONTROL_PASSWORD` |
| Worker morto | Tarefa recorrente `recover_interrupted_webhooks`, a cada minuto no `jobs-default`, reprocessa os jobs de webhook que estão na fila de falhas por morte do processo (`ProcessExitError`, `ProcessPrunedError`, `ProcessMissingError`). Heartbeat no padrão da gem: 60 s, e processo morto depois de 5 min sem heartbeat |

## Arquivos

### Core (`core/`)

| Arquivo | Conteúdo |
| - | - |
| `app/jobs/application_job.rb` | `EXPONENTIAL_BACKOFF`, a lambda de backoff exponencial com jitter compartilhada |
| `app/modules/channels/delivery_job.rb` | `retry_on` com o backoff do `ApplicationJob` |
| `app/modules/channels/email/ingest_job.rb` | `retry_on` com o backoff do `ApplicationJob` |
| `app/modules/agents/settings.rb` | Leitura de `BROKER_WEBHOOK_URL` e `BROKER_WEBHOOK_SECRET` no momento do uso |
| `app/modules/agents/webhook_error.rb` | `Agents::WebhookError::Transient` e `Agents::WebhookError::Permanent` |
| `app/modules/agents/broker_client.rb` | `POST` assinado ao Broker e classificação da resposta |
| `app/modules/agents/webhook_delivery_job.rb` | Leitura do evento e da conversa, `webhook.skipped`, montagem do corpo, envio e retry |
| `app/modules/agents/recover_interrupted_webhooks_job.rb` | Reprocessamento dos jobs de webhook que falharam pela morte do processo |
| `config/recurring.yml` | Tarefa `recover_interrupted_webhooks`, a cada minuto |
| `config/queue.yml` | Processo `jobs-default`: dispatcher, worker de `channels` e worker de `default` e das filas do Action Mailbox |
| `config/queue_webhooks.yml` | Processo `jobs-webhooks`: dispatcher e worker de `webhooks` |
| `config/initializers/mission_control.rb` | Credenciais do basic auth do painel |
| `config/routes.rb` | `mount MissionControl::Jobs::Engine, at: "/jobs"` |
| `Gemfile` e `Gemfile.lock` | Gem `mission_control-jobs` 1.3.1 |

### Raiz

| Arquivo | Conteúdo |
| - | - |
| `.env.example` | `BROKER_WEBHOOK_URL`, `BROKER_WEBHOOK_SECRET`, `MISSION_CONTROL_USER` e `MISSION_CONTROL_PASSWORD` |
| `compose.yaml` | Variáveis no bloco `x-rails`, âncora `rails-environment` e serviço `jobs-webhooks` |

## Envio

### Job

`Agents::WebhookDeliveryJob.perform(brand_id:, event_id:, traceparent:)`:

1. Continua o trace do evento (`TraceContext.continue`): o salto do envio é filho do salto que gravou o evento, com o mesmo `trace_id`.
2. Em um `Tenancy.with_brand` da marca do job:
   - lê o `audit_event` pelo `event_id` e o envelope gravado em `payload`;
   - evento que não é `message.created`: `WebhookError::Permanent`;
   - lê a conversa; fora de `with_ai`, grava `webhook.skipped` e termina;
   - monta o corpo com `Contract::MessageCreated.build`, que valida o schema `webhook.message-created`, e o serializa em JSON. Corpo fora do schema vira `WebhookError::Permanent`.
3. Fora da transação, envia pelo `Agents::BrokerClient`.

O envio fora da transação não segura conexão do banco nem trava durante a chamada ao Broker. A leitura do evento e da conversa usa a conexão por poucos milissegundos.

### Cliente

`Agents::BrokerClient.deliver(body:, traceparent:)`:

- `POST` em `BROKER_WEBHOOK_URL`, com `Content-Type: application/json` e `traceparent`;
- `Contract::Signature.headers` sobre `POST`, `uri.request_uri` (caminho com a query string) e o mesmo texto do corpo enviado;
- `Net::HTTP.start` com `open_timeout` de 2 s e `read_timeout` de 5 s. No Ruby 3.4, o `open_timeout` cobre a resolução de nome: com o `broker-web` fora do Compose, o DNS do Docker demora cerca de 7,7 s para negar o nome, e o envio termina em `Net::OpenTimeout` aos 2 s.

| Resultado | Classe | Efeito no job |
| - | - | - |
| 2xx | sucesso | o job termina |
| 408, 429, 5xx | `WebhookError::Transient` | nova tentativa com backoff |
| `Net::OpenTimeout`, `Net::ReadTimeout`, `ECONNREFUSED`, `ECONNRESET`, `EHOSTUNREACH`, `ENETUNREACH`, `ETIMEDOUT`, `EPIPE`, `SocketError` (inclui falha de DNS), `EOFError` | `WebhookError::Transient` | nova tentativa com backoff |
| Demais status | `WebhookError::Permanent` | fila de falhas, sem nova tentativa |

1xx e 3xx são permanentes: o Net::HTTP não segue redirecionamento, e um redirecionamento indica URL errada, que nova tentativa não corrige.

### Retry

`retry_on WebhookError::Transient, wait: EXPONENTIAL_BACKOFF, attempts: 10`. A espera depois da tentativa `n` é `2^n` segundos mais até 15%; as nove esperas somam entre 1.022 s e 1.175 s, cerca de 17 minutos. Na décima falha, o `retry_on` relança o erro e o Solid Queue grava o job em `solid_queue_failed_executions`.

O Active Job conta as tentativas do `retry_on` por exceção, em `exception_executions`, e não em `executions`. Cada nova tentativa é uma linha nova em `solid_queue_jobs`, com o mesmo `active_job_id`.

O reprocessamento pelo painel (`SolidQueue::FailedExecution#retry`) zera `executions` e `exception_executions`: o job reprocessado tem um novo ciclo de 10 tentativas.

### Estado da conversa

O `Conversations::Intake` enfileira o webhook só com a conversa em `with_ai` (F6). Entre a gravação e o envio, a conversa pode mudar de estado: escalada, resolvida ou devolvida à triagem. O job confere o estado de novo e, fora de `with_ai`, grava pelo `Audit::Command`:

| Campo | Valor |
| - | - |
| `action` | `webhook.skipped` |
| `actor_type` | `system` |
| alvo | a `Message` do evento |
| `reason` | `conversa em <estado>` |
| `payload` | `event_id` do `message.created` e `state` |
| webhook | não |

A conferência reduz trabalho inútil do agente, mas não fecha a corrida entre o envio e a ação. A barreira é a recusa da ação com a conversa fora de `with_ai` na API de ações (F8), descrita em `documents/arquitetura.md`, seção "Ação com a conversa fora da IA".

### Auditoria e linha do tempo

A resposta 2xx do Broker não grava `audit_event`: um evento por entrega dobraria as gravações em `audit_events` na carga do experimento. A linha do tempo da mensagem recebe `broker_received_at` e `kafka_appended_at` pelo `audit_event` da ação do agente (F8), e as tentativas de cada job ficam visíveis no painel.

## Processos

| Serviço | Comando | Configuração |
| - | - | - |
| `jobs-default` | `bin/jobs` | `config/queue.yml` e `config/recurring.yml` |
| `jobs-webhooks` | `bin/jobs --config-file config/queue_webhooks.yml --skip-recurring` | `config/queue_webhooks.yml`, sem tarefas recorrentes |

As opções `--config-file` e `--skip-recurring` são as do `SolidQueue::Cli` 1.7.2, conferidas no contêiner. O `bin/jobs check` valida as duas configurações.

| Processo | Worker | Threads | Polling |
| - | - | - | - |
| `jobs-default` | `channels` | 3 | 0,1 s |
| `jobs-default` | `default`, `action_mailbox_routing`, `action_mailbox_incineration` | 3 | 1 s |
| `jobs-webhooks` | `webhooks` | 5 | 0,1 s |

Cada processo tem um dispatcher próprio, com polling de 1 s e lote de 500. O polling de 0,1 s é o padrão da gem para workers. Com 1 s, a espera do job antes do envio chega perto de 1 s e inviabiliza a H2 (p95 entrada → Kafka < 300 ms). A fila `channels` entra na latência ponta a ponta (H4) e tem o mesmo polling.

### Pool de conexões

O Solid Queue estima as conexões de um worker em threads + 2 (uma para o polling e uma para o heartbeat) e avisa quando o pool é menor. O `config/database.yml` usa `max_connections` igual a `RAILS_MAX_THREADS`, com padrão 5:

- `jobs-default`: workers de 3 threads, 5 conexões, sem aviso;
- `jobs-webhooks`: worker de 5 threads, 7 conexões. O serviço define `RAILS_MAX_THREADS=7`.

No Compose, o `environment` do `jobs-webhooks` mescla a âncora `rails-environment`: a mesclagem do YAML é rasa, e um `environment` próprio sem ela substituiria o do `x-rails` inteiro.

## Worker morto

No Solid Queue 1.7.2, no desligamento normal, o worker se desregistra e devolve à fila os jobs que ainda estão com ele. Quando o processo morre, os jobs que ele executava vão para a fila de falhas com um erro gravado pelo próprio Solid Queue, fora do `retry_on`:

| Situação | Quem percebe | Quando | Erro |
| - | - | - | - |
| O fork do worker termina com erro, e o supervisor está vivo | o supervisor do processo | na hora, e o supervisor sobe outro fork | `ProcessExitError` |
| O contêiner inteiro morre (`docker kill`) | a manutenção de qualquer supervisor (`jobs-default` ou o `jobs-webhooks` de volta) | quando o último heartbeat tem mais de `process_alive_threshold` (5 min); o heartbeat é a cada 60 s, e a manutenção roda na subida do supervisor e a cada 5 min, então leva de 4 a 10 min depois da morte | `ProcessPrunedError` |
| O job está com um processo que não existe mais | o supervisor, na subida | na subida | `ProcessMissingError` |

O `Agents::RecoverInterruptedWebhooksJob`, tarefa recorrente `recover_interrupted_webhooks` do `jobs-default`, roda a cada minuto e reprocessa (`SolidQueue::FailedExecution#retry`) os jobs de `Agents::WebhookDeliveryJob` na fila de falhas com um desses três erros. O reprocessamento é o mesmo do painel e começa um novo ciclo de tentativas. As demais falhas, como Broker recusando ou tentativas esgotadas, ficam na fila de falhas.

Se o processo morreu depois do `POST`, o webhook sai de novo. A entrega é at-least-once: o agente gera a ação com a mesma `Idempotency-Key`, e o Core descarta a repetição (F8).

O heartbeat fica no padrão da gem (60 s, e processo morto depois de 5 min). Com ele, o webhook de um contêiner morto volta à fila de 4 a 11 minutos depois da morte. A F15 mede e ajusta esses valores.

## Painel

O Mission Control - Jobs 1.3.1 é montado em `/jobs` no `web` e acessado em `http://localhost:3000/jobs`. Mostra filas, jobs agendados, em execução, concluídos e com falha, com os botões de reprocessar e descartar.

- O controller da gem herda do `ApplicationController` do app, com o `allow_browser`.
- O basic auth da gem é ligado por padrão. As credenciais vêm de `MISSION_CONTROL_USER` e `MISSION_CONTROL_PASSWORD`, lidas na inicialização; sem elas, a gem recusa o acesso.
- O papel `cloudesk_app` tem `SELECT`, `INSERT`, `UPDATE` e `DELETE` nas 13 tabelas do Solid Queue. Reprocessar e descartar não pedem permissão nova.

## Testes

| Arquivo | Cobertura |
| - | - |
| `spec/modules/agents/broker_client_spec.rb` | Corpo enviado sem nova serialização, `Content-Type` e `traceparent`; assinatura conferida com `Contract::Signature.verify!`, com o caminho e a query string; timestamp e assinatura por envio; outro segredo não confere; 2xx, 408, 429, 5xx, 4xx e 3xx; erros de rede, DNS e timeouts |
| `spec/modules/agents/webhook_delivery_job_spec.rb` | Fila `webhooks`; envio com a conversa em `with_ai`, corpo igual ao do contrato e assinado; trace continuado no header; 2xx sem `audit_event`; `webhook.skipped` sem chamada HTTP em `awaiting_human` e `triage`; evento de outro tipo; marca errada; retry agendado com backoff em 503 e em conexão recusada; falha na décima tentativa sem novo agendamento; 4xx sem retry; soma das esperas |
| `spec/modules/agents/recover_interrupted_webhooks_job_spec.rb` | Reprocessamento com `ProcessPrunedError`, `ProcessMissingError` e `ProcessExitError`, com o contador zerado; falha por tentativas esgotadas fica; outro job morto com o processo fica; tarefa a cada minuto no `recurring.yml` |
| `spec/requests/mission_control_spec.rb` | `/jobs` sem credencial e com senha errada responde 401; com a credencial responde 200 |
| `spec/support/agents.rb` | Endereço e segredos fixos dos testes e conferência da assinatura de uma requisição do WebMock |

Os testes de `Channels::DeliveryJob` e `Channels::Email::IngestJob` cobrem o backoff compartilhado. A suíte completa do RSpec roda no contêiner: 550 exemplos, sem falha.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`:

- com o Broker fora do ar, os jobs são reenviados com backoff; um job esgotado aparece na fila de falhas e é reprocessado pelo painel: `webhook_delivery_job_spec.rb` e a prova no Compose;
- a requisição segue o schema `webhook.message-created` e a assinatura confere com `Contract::Signature.verify!`: `broker_client_spec.rb` e `webhook_delivery_job_spec.rb`;
- conversa fora de `with_ai` não gera chamada ao Broker e grava `webhook.skipped`: `webhook_delivery_job_spec.rb`;
- `jobs-webhooks` atende só a fila `webhooks`, e `jobs-default` atende as demais: `solid_queue_processes` no Compose.

A entrega depois da volta do Broker é verificada na F9, quando o `broker-web` existe.

### Prova no Compose

Com `web`, `jobs-default` e `jobs-webhooks` no ar e sem o `broker-web`:

1. `solid_queue_processes` mostra, no contêiner do `jobs-webhooks`, um dispatcher e um worker só da fila `webhooks` (5 threads, polling de 0,1 s), sem scheduler; no contêiner do `jobs-default`, um dispatcher, o worker de `channels` (0,1 s), o worker de `default` e das filas do Action Mailbox (1 s) e o scheduler das tarefas recorrentes.
2. `send` do simulador com 6 mensagens de WhatsApp nas duas marcas: 6 respostas 200 e os jobs de webhook das conversas em `with_ai` na fila `webhooks`.
3. Cada tentativa termina em `Net::OpenTimeout` aos 2 s e agenda a seguinte com as esperas de 2,3 s, 4,5 s, 8,7 s, 18 s e 36 s, dentro de `2^n` mais até 15%.
4. Os jobs de webhook acumulados das fases anteriores entram junto: os de conversas fora de `with_ai` gravam `webhook.skipped`; os demais seguem o retry. Com cerca de 75 jobs, 5 threads e 2 s por tentativa, cada tentativa roda até cerca de 30 s depois do horário agendado.
5. Cerca de 22 minutos depois do envio, nenhum job de webhook está pendente e 75 estão na fila de falhas com `Agents::WebhookError::Transient`.
6. `/jobs` responde 401 sem credencial e 200 com ela. O botão de reprocessar de um job da fila de falhas responde 302 de volta à lista; a fila de falhas cai para 74, e o job roda de novo e agenda a próxima tentativa.
7. Com 20 mensagens no simulador, `docker kill` no `jobs-webhooks` às 23:21:41, com 5 jobs em execução e o último heartbeat às 23:21:10. O `jobs-webhooks` volta com `docker compose start`. Até 23:26:37, a manutenção do Solid Queue grava os 5 jobs na fila de falhas com `ProcessPrunedError`; até 23:27:08, a tarefa `recover_interrupted_webhooks` os devolve à fila (`webhooks interrompidos devolvidos à fila: 5` no log), cerca de 5,5 minutos depois da morte.

## Pontos de atenção

- **Ordem dos webhooks.** Webhooks da mesma conversa podem chegar ao Broker fora de ordem por causa dos retries; o agente decide pelo contexto mais recente lido na `context_url`.
- **Custo do polling.** Com várias réplicas, o polling de 0,1 s gera 10 consultas por segundo por worker parado. A F15 mede esse custo e dimensiona threads, processos, réplicas e pool.
- **Broker fora do Compose.** Sem o serviço `broker-web`, cada tentativa espera os 2 s do timeout de conexão, porque o DNS do Docker demora a negar o nome. Com o serviço parado mas declarado, o efeito é o mesmo; com o serviço no ar e o processo recusando a conexão, a falha é imediata.
- **Jobs de webhook acumulados.** Os jobs de webhook gravados antes da existência do `jobs-webhooks` ficam na fila `webhooks` e são processados quando o processo sobe: os de conversas fora de `with_ai` gravam `webhook.skipped`, e os demais seguem o retry até a fila de falhas.
- **Demora da recuperação.** Com o heartbeat padrão, o webhook de um contêiner `jobs-webhooks` morto volta à fila de 4 a 11 minutos depois da morte. Na H3, essas mensagens chegam atrasadas, não perdidas; a F15 decide se reduz `process_heartbeat_interval` e `process_alive_threshold`.
- **Outros jobs.** A recuperação automática cobre só o `Agents::WebhookDeliveryJob`. Os demais jobs interrompidos pela morte do processo ficam na fila de falhas.
- **Credenciais do painel.** São lidas na inicialização do `web`; mudar a senha pede reinício do processo.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F8 | O job confere o estado só antes do envio | A API de ações recusa a ação com a conversa fora de `with_ai` e grava `audit_event`; o código HTTP da recusa é decidido na F8 |
| F9 | O Core envia a `BROKER_WEBHOOK_URL` com `BROKER_WEBHOOK_SECRET` | O `broker-web` atende `POST /webhooks/message-created`, confere a assinatura com o mesmo segredo e o caminho com a query string, e responde 2xx só depois da confirmação do Kafka; 408, 429 e 5xx geram nova tentativa, e os demais status vão para a fila de falhas |
| F14 | As tentativas ficam no Solid Queue | A profundidade da fila `webhooks` e as falhas entram nas métricas |
| F15 | Threads, polling, pool e heartbeat são valores iniciais | Dimensionamento por medida, com réplicas do `jobs-webhooks`, e ajuste de `process_heartbeat_interval` e `process_alive_threshold` |
| F17 | O `docker kill` em um worker `jobs-webhooks` deixa os jobs em execução na fila de falhas até a detecção | A tarefa `recover_interrupted_webhooks` os reprocessa; a reconciliação da H3 considera a demora de 4 a 11 minutos |

## Fontes

- [Solid Queue · README (configuração, workers, dispatchers, polling e tarefas recorrentes)](https://github.com/rails/solid_queue)
- [Mission Control - Jobs · README](https://github.com/rails/mission_control-jobs)
- [Rails Guides · Active Job Basics (`retry_on`)](https://guides.rubyonrails.org/active_job_basics.html)
- Código das gems no contêiner: `solid_queue` 1.7.2 (`lib/solid_queue/cli.rb` e `lib/solid_queue/configuration.rb`), `mission_control-jobs` 1.3.1 (`lib/mission_control/jobs.rb`, `lib/mission_control/jobs/engine.rb` e `app/controllers/concerns/mission_control/jobs/basic_authentication.rb`) e `activejob` 8.1.4.1 (`lib/active_job/exceptions.rb`)
- `documents/fases/04-contrato-de-integracao.md`, seções "Webhook `message.created`" e "Assinatura"
- Código do Solid Queue 1.7.2 sobre processos encerrados: `app/models/solid_queue/process/executor.rb`, `app/models/solid_queue/process/prunable.rb`, `lib/solid_queue/supervisor/maintenance.rb` e `lib/solid_queue/fork_supervisor.rb`
- `documents/arquitetura.md`, seção "Ação com a conversa fora da IA"

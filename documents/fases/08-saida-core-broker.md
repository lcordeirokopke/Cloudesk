# Cloudesk · Saída do Core para o Broker

## O que é

A saída do Core para o Broker é o trecho que avisa o agente de IA de cada mensagem nova do lojista. Quando uma mensagem chega a uma conversa atendida pela IA, o Core envia ao Broker o webhook `message.created`, assinado e no formato do contrato; o Broker o publica no Kafka, de onde o agente o consome.

Esse aviso não pode se perder. Uma mensagem sem webhook é um lojista sem resposta, e nenhuma outra parte do sistema perceberia a falta. Por isso a saída é construída sobre três garantias:

- **o aviso nasce junto com a mensagem:** o job de envio é gravado na mesma transação da mensagem e do `audit_event`;
- **o aviso insiste até ser confirmado:** falhas transitórias têm novas tentativas com backoff exponencial e jitter, e o Broker só confirma depois do Kafka;
- **o aviso que não pôde sair fica visível:** esgotadas as tentativas, o job fica na fila de falhas e é reprocessado pelo painel do Mission Control - Jobs.

## Onde fica no fluxo

```text
Canal → Core (web): mensagem + audit_event + job de webhook, na mesma transação
          │
          ▼
     jobs-webhooks: Agents::WebhookDeliveryJob
          │  POST assinado (message.created)
          ▼
     Broker (broker-web) → Kafka (agent.inbound) → agente
```

O `web` grava e o `jobs-webhooks` envia. Entre os dois, o job fica no Solid Queue, no mesmo PostgreSQL do domínio: é o outbox implícito da arquitetura (`documents/arquitetura.md`, "Decisões de design").

## Por que existe e que valor gera

**Nenhuma mensagem perdida.** O job de envio é persistido na mesma transação da mensagem. Se o processo cai depois do commit, o job já existe; se a transação falha, não existe mensagem nem job. Não há janela em que a mensagem foi aceita e o aviso ficou só na memória de um processo. Essa é a base da hipótese H3 do experimento.

**Tolerância à queda do Broker e do Kafka.** Com o Broker fora do ar, o Core continua recebendo mensagens normalmente, e os avisos esperam na fila com novas tentativas por cerca de 17 minutos. Uma queda curta, como um `docker restart`, se resolve sozinha; uma queda longa deixa os avisos na fila de falhas, de onde voltam com um clique.

**Tolerância à morte do próprio worker.** Se o processo que envia os webhooks morre no meio do trabalho, os jobs que ele executava voltam à fila automaticamente, sem intervenção da operação.

**Isolamento do caminho crítico.** O envio de webhooks roda em um processo próprio, o `jobs-webhooks`, que atende só a fila `webhooks`. Um acúmulo de tarefas internas, como a ingestão de e-mails, não atrasa o aviso ao agente, e o volume de saída para o Broker escala por réplicas desse processo, sem levar junto o resto.

**Fronteira entre IA e humano.** Antes de enviar, o job confere se a conversa ainda está com a IA. Se um analista assumiu ou a conversa foi resolvida enquanto o aviso esperava na fila, o agente não é acionado à toa.

**Operação visível.** O painel em `/jobs` mostra filas, tentativas, falhas e o erro de cada uma, e permite reprocessar ou descartar. A operação enxerga o que está preso e por quê, sem acesso ao banco.

## Como funciona

### O envio

`Agents::WebhookDeliveryJob` recebe só a marca, o `event_id` e o `traceparent`. O corpo do webhook não viaja no job: ele é lido do `audit_event` da mensagem, que guarda o envelope canônico. O `event_id` do webhook é o mesmo do `audit_event`, e com isso todo aviso tem origem rastreável na auditoria.

A cada execução, o job:

1. **continua o trace** do evento: o envio é um salto filho do salto que gravou a mensagem, com o mesmo `trace_id`;
2. **lê o evento e a conversa** dentro da marca do job (`Tenancy.with_brand`), com o Row-Level Security aplicado;
3. **confere o estado:** fora de `with_ai`, grava `webhook.skipped` e termina sem chamar o Broker;
4. **monta o corpo** com `Contract::MessageCreated.build`, que valida o schema `webhook.message-created` do contrato;
5. **envia** pelo `Agents::BrokerClient`, já fora da transação.

O envio fora da transação é deliberado: a chamada HTTP não segura conexão do banco nem trava linhas enquanto espera o Broker. A leitura do evento e da conversa usa a conexão por poucos milissegundos.

### A requisição

| Item | Valor |
| - | - |
| Destino | `POST` em `BROKER_WEBHOOK_URL` (`http://broker-web:3000/webhooks/message-created`) |
| Headers | `Content-Type: application/json`, `traceparent`, `X-Cloudesk-Timestamp` e `X-Cloudesk-Signature` |
| Assinatura | HMAC-SHA256 com `BROKER_WEBHOOK_SECRET` sobre `<timestamp>.POST.<caminho>.<corpo>`, no esquema do contrato (`documents/fases/04-contrato-de-integracao.md`) |
| Corpo | Serializado uma única vez; a assinatura é calculada sobre os mesmos bytes enviados |
| Timeouts | 2 s para conectar, inclusive a resolução de nome, e 5 s para ler a resposta |

Cada tentativa gera timestamp e assinatura próprios, e uma tentativa feita minutos depois da primeira continua dentro da janela de 300 s do anti-replay.

### Como a resposta é tratada

| Resultado | Tratamento |
| - | - |
| 2xx | Sucesso: o job termina |
| 408, 429, 5xx | Transitório: nova tentativa com backoff |
| Erro de rede: timeout, conexão recusada ou interrompida, falha de DNS | Transitório: nova tentativa com backoff |
| Demais status (1xx, 3xx e os outros 4xx) | Permanente: fila de falhas, sem nova tentativa |
| Evento que não é `message.created`, corpo fora do schema | Permanente: fila de falhas, sem nova tentativa |

A classificação separa o que o tempo resolve do que só uma correção resolve. Um Broker sobrecarregado ou reiniciando volta a responder; um `401` por segredo errado ou um redirecionamento por URL errada não mudam com novas tentativas, e insistir só atrasaria a percepção do problema.

### Novas tentativas

As falhas transitórias usam `retry_on` com 10 tentativas e `ApplicationJob::EXPONENTIAL_BACKOFF`: depois da tentativa `n`, a espera é de `2^n` segundos mais até 15%. As nove esperas somam entre 1.022 s e 1.175 s, cerca de 17 minutos. Na décima falha, o job vai para a fila de falhas do Solid Queue.

O jitter de até 15% espalha as novas tentativas: quando o Broker volta, os jobs acumulados não chegam todos no mesmo instante. A mesma regra de backoff serve a entrega das respostas aos canais (`Channels::DeliveryJob`) e a ingestão de e-mails (`Channels::Email::IngestJob`).

Um job reprocessado pelo painel começa um novo ciclo de 10 tentativas.

### Conversa que saiu da IA

O `Conversations::Intake` enfileira o webhook só com a conversa em `with_ai`. Entre a gravação e o envio, porém, a conversa pode mudar: ser escalada, resolvida ou devolvida à triagem. O job confere o estado de novo e, fora de `with_ai`, grava pelo `Audit::Command`:

| Campo | Valor |
| - | - |
| `action` | `webhook.skipped` |
| `actor_type` | `system` |
| alvo | a mensagem do evento |
| `reason` | `conversa em <estado>` |
| `payload` | `event_id` do `message.created` e o estado da conversa |

O registro explica na linha do tempo por que aquela mensagem não gerou ação da IA.

A conferência poupa trabalho do agente, mas não fecha sozinha a corrida entre o envio e a ação: a conversa pode sair da IA depois que o webhook saiu. A barreira final é a API de ações, que recusa com `409 rejected` toda ação sobre conversa fora de `with_ai` (`documents/fases/09-api-de-acoes-e-contexto.md`).

### Worker morto

Quando o processo do `jobs-webhooks` morre, o Solid Queue grava os jobs que ele executava na fila de falhas, com um erro próprio, fora do `retry_on`:

| Situação | Quem percebe | Quando | Erro |
| - | - | - | - |
| O fork do worker termina com erro, com o supervisor vivo | o supervisor | na hora; o supervisor sobe outro fork | `ProcessExitError` |
| O contêiner inteiro morre (`docker kill`) | a manutenção de qualquer supervisor | depois de 5 min sem heartbeat; com heartbeat a cada 60 s e manutenção a cada 5 min, entre 4 e 10 min depois da morte | `ProcessPrunedError` |
| O job está com um processo que não existe mais | o supervisor, na subida | na subida | `ProcessMissingError` |

A tarefa recorrente `recover_interrupted_webhooks` (`Agents::RecoverInterruptedWebhooksJob`), no `jobs-default`, roda a cada minuto e reprocessa os jobs de webhook que estão na fila de falhas com um desses três erros. O reprocessamento é o mesmo do botão do painel. Falhas de outra natureza, como Broker recusando ou tentativas esgotadas, continuam na fila de falhas para análise.

Se o processo morreu depois do `POST`, o webhook sai de novo. A entrega é at-least-once: o agente gera a ação com a mesma `Idempotency-Key`, e o Core descarta a repetição. A saída pode repetir um aviso, mas nunca o perde; a deduplicação é responsabilidade da API de ações.

### Processos

| Serviço | Comando | Worker | Threads | Polling |
| - | - | - | - | - |
| `jobs-webhooks` | `bin/jobs --config-file config/queue_webhooks.yml --skip-recurring` | `webhooks` | 5 | 0,1 s |
| `jobs-default` | `bin/jobs` | `channels` | 3 | 0,1 s |
| `jobs-default` | `bin/jobs` | `default`, `action_mailbox_routing`, `action_mailbox_incineration` | 3 | 1 s |

- Cada processo tem o próprio dispatcher, com polling de 1 s e lote de 500. As tarefas recorrentes rodam só no `jobs-default`.
- O polling de 0,1 s da fila `webhooks` mantém curta a espera do job antes do envio, que entra na latência entrada → Kafka (H2). Com 1 s, essa espera sozinha consumiria boa parte da meta de 300 ms. A fila `channels`, que entrega as respostas ao lojista, entra na latência ponta a ponta (H4) e tem o mesmo polling.
- O Solid Queue usa threads + 2 conexões por worker (polling e heartbeat). O worker de 5 threads usa 7, e o serviço `jobs-webhooks` define `RAILS_MAX_THREADS=7`; os workers de 3 threads cabem no padrão de 5.

### Painel

O Mission Control - Jobs 1.3.1 fica em `/jobs`, no `web` (`http://localhost:3000/jobs`), protegido por HTTP basic auth com `MISSION_CONTROL_USER` e `MISSION_CONTROL_PASSWORD`. Sem as credenciais configuradas, a gem recusa todo acesso.

O painel mostra filas, jobs agendados, em execução, concluídos e com falha, com o erro de cada falha e os botões de reprocessar e descartar. O papel `cloudesk_app` já tem as permissões necessárias nas tabelas do Solid Queue.

### Auditoria

A resposta 2xx do Broker não gera `audit_event`: um registro por entrega dobraria as gravações em `audit_events` na carga do experimento, sem informação nova. A chegada ao Broker e ao Kafka fica registrada pelos carimbos `broker_received_at` e `kafka_appended_at`, que voltam com a ação do agente e são gravados no `audit_event` dela. O trace continuado no header `traceparent` liga o envio à mensagem de origem. As tentativas de cada job ficam no painel.

## O que o sistema garante

- Toda mensagem aceita em conversa com a IA tem um job de webhook gravado na mesma transação.
- Falhas transitórias do Broker, do Kafka ou da rede não perdem o aviso: ele é reenviado até ser confirmado ou ficar na fila de falhas.
- Nenhum job some em silêncio: o que não foi entregue está na fila de falhas, com o erro, e pode ser reprocessado.
- A morte do worker não perde os jobs que ele executava: eles voltam à fila sozinhos.
- Toda requisição ao Broker segue o schema do contrato e é assinada.
- Conversa fora da IA no momento do envio não aciona o agente e deixa `webhook.skipped` na auditoria.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Integração com o atendente por webhooks e broker | O webhook de ida: envio assinado, no contrato, com retry, fila de falhas e reprocessamento | Contrato e assinatura (F3), Broker (F9), API de ações (F8) e agente (F10) |
| Triagem, priorização e distribuição entre IA e analistas | O agente é acionado só para conversas que estão com a IA no momento do envio | Classificação e roteamento (F6), escalação e distribuição ao analista (F11) |
| Rastreabilidade e auditoria | `event_id` do webhook igual ao do `audit_event`, trace continuado e `webhook.skipped` com o motivo | Carimbos da ação (F8) e linha do tempo na tela (F14) |
| Empacotamento self-hosted | Processos `jobs-webhooks` e `jobs-default` no Compose e o painel `/jobs` | Demais serviços (F0 e F9) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min sem acúmulo crescente de backlog | A profundidade da fila `webhooks` é uma das medidas de backlog, e o `jobs-webhooks` escala por réplicas independentes |
| H2 · entrada → Kafka com p95 < 300 ms | O trecho entre o commit da mensagem e o `POST` ao Broker está aqui: espera na fila (polling de 0,1 s), leitura do evento e envio |
| H3 · nada perdido nem duplicado, com Broker reiniciado e worker morto | O outbox implícito e as novas tentativas cobrem o reinício do Broker; a recuperação automática cobre o `docker kill` no `jobs-webhooks`. A duplicação que a reentrega pode causar é barrada na API de ações |
| H4 · ponta a ponta com p95 < 1 s, descontado o agente | A espera da fila `webhooks` e a da fila `channels`, na volta, compõem a latência percebida pelo lojista |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 2 · Cockpit operacional | A profundidade da fila `webhooks` e as falhas de entrega são dados de origem do painel de backlog do Solid Queue (F14) |
| 5 · Modos de falha do agente mock | Os modos de atraso e de ação duplicada pressupõem que o aviso chegou ao agente; a saída garante essa chegada mesmo com falhas no caminho, e a resposta a cada modo fica com a API de ações e a varredura de SLA |

Além dos diferenciais listados no escopo, a recuperação automática dos webhooks interrompidos pela morte do worker vai além do que o Solid Queue oferece por padrão, que é deixar esses jobs na fila de falhas à espera de ação manual.

## Limitações

- **Demora da recuperação.** Com o heartbeat padrão da gem (60 s, e processo morto depois de 5 min), o webhook de um contêiner `jobs-webhooks` morto volta à fila entre 4 e 11 minutos depois da morte. Na H3, essas mensagens chegam atrasadas, não perdidas. Os valores de `process_heartbeat_interval` e `process_alive_threshold` são ajustados por medida na F15.
- **Recuperação só dos webhooks.** A recuperação automática cobre só o `Agents::WebhookDeliveryJob`. Outros jobs interrompidos pela morte do processo ficam na fila de falhas para reprocessamento manual.
- **Ordem dos avisos.** Webhooks da mesma conversa podem chegar ao Broker fora de ordem, porque as threads são paralelas e as novas tentativas têm esperas diferentes. O agente decide pelo contexto mais recente lido na `context_url`, e a API de ações recusa a ação desatualizada.
- **Corrida com a mudança de estado.** A conferência do estado acontece antes do envio; a conversa pode sair da IA logo depois. A barreira é a recusa `409 rejected` na API de ações.
- **Custo do polling.** O polling de 0,1 s gera 10 consultas por segundo por worker ocioso. Com várias réplicas, o custo cresce, e a F15 o mede junto com threads, processos e pool.
- **Timeout com o Broker ausente.** Com o `broker-web` fora do Compose ou parado, cada tentativa espera os 2 s do timeout de conexão, porque o DNS do Docker demora a negar o nome. Com o processo no ar recusando a conexão, a falha é imediata.
- **Limite das tentativas.** Uma queda do Broker mais longa que cerca de 17 minutos deixa os avisos na fila de falhas, e eles só voltam por reprocessamento no painel.
- **Credenciais do painel.** São lidas na inicialização do `web`; trocar a senha pede reinício do processo.

## Operação

### Configuração

| Variável | Uso |
| - | - |
| `BROKER_WEBHOOK_URL` | Endereço do Broker; o caminho assinado é o da URI, com a query string |
| `BROKER_WEBHOOK_SECRET` | Segredo da assinatura, compartilhado com o `broker-web` |
| `MISSION_CONTROL_USER`, `MISSION_CONTROL_PASSWORD` | Credenciais do painel `/jobs` |

As variáveis ficam no `.env` e chegam aos serviços Rails pela âncora `rails-environment` do `compose.yaml`. O `environment` do `jobs-webhooks` mescla essa âncora e acrescenta `RAILS_MAX_THREADS=7`.

### Arquivos principais

| Arquivo | Conteúdo |
| - | - |
| `core/app/modules/agents/webhook_delivery_job.rb` | Leitura do evento e da conversa, `webhook.skipped`, montagem do corpo, envio e retry |
| `core/app/modules/agents/broker_client.rb` | `POST` assinado e classificação da resposta |
| `core/app/modules/agents/webhook_error.rb` | Erros `Transient` e `Permanent` |
| `core/app/modules/agents/recover_interrupted_webhooks_job.rb` | Reprocessamento dos jobs interrompidos pela morte do processo |
| `core/app/jobs/application_job.rb` | `EXPONENTIAL_BACKOFF`, compartilhado pelos jobs com retry |
| `core/config/queue.yml` e `core/config/queue_webhooks.yml` | Workers e dispatchers de `jobs-default` e `jobs-webhooks` |
| `core/config/recurring.yml` | Tarefa `recover_interrupted_webhooks`, a cada minuto |
| `core/config/initializers/mission_control.rb` e `core/config/routes.rb` | Credenciais e montagem do painel em `/jobs` |

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/agents/broker_client_spec.rb` | Corpo enviado sem nova serialização; headers; assinatura conferida com `Contract::Signature.verify!`, com caminho e query string; timestamp e assinatura por envio; classificação de 2xx, 408, 429, 5xx, 4xx, 3xx, erros de rede, DNS e timeouts |
| `core/spec/modules/agents/webhook_delivery_job_spec.rb` | Fila `webhooks`; corpo conforme o contrato e assinado; trace continuado; 2xx sem `audit_event`; `webhook.skipped` sem chamada HTTP fora de `with_ai`; evento de outro tipo; marca errada; retry com backoff; fila de falhas na décima tentativa; 4xx sem retry; soma das esperas |
| `core/spec/modules/agents/recover_interrupted_webhooks_job_spec.rb` | Reprocessamento com os três erros de processo e contador zerado; falha por tentativas esgotadas e outros jobs permanecem; tarefa no `recurring.yml` |
| `core/spec/requests/mission_control_spec.rb` | `/jobs` responde 401 sem credencial ou com senha errada e 200 com a credencial |

No Compose, sem o `broker-web`, as mensagens enviadas pelo simulador são aceitas normalmente, e os jobs de webhook seguem as novas tentativas com esperas de cerca de 2 s, 4 s, 8 s, 16 s e 32 s, mais o jitter, até a fila de falhas; o reprocessamento pelo painel devolve o job à fila com um novo ciclo. Com um `docker kill` no `jobs-webhooks` durante o envio, os jobs em execução vão para a fila de falhas com `ProcessPrunedError` e voltam à fila pela tarefa `recover_interrupted_webhooks`, que registra no log `webhooks interrompidos devolvidos à fila: <n>`. A tabela `solid_queue_processes` mostra o `jobs-webhooks` só com a fila `webhooks` e sem scheduler, e o `jobs-default` com as demais filas e as tarefas recorrentes.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Núcleo transacional e auditoria (F2) | O `Audit::Command` grava o `audit_event` e enfileira o job na mesma transação; o envelope do webhook vem do `audit_event` |
| Contrato (F3) | Define o schema `webhook.message-created` e a assinatura; esta parte implementa o envio do lado do Core |
| Canais (F4) | Compartilha a regra de backoff com a entrega das respostas e a ingestão de e-mails |
| Roteamento (F6) | Decide se a conversa fica com a IA, o que define se o webhook é enfileirado |
| API de ações (F8) | É a barreira final contra duplicação e contra ação sobre conversa fora da IA; recebe os carimbos de horário do Broker e do Kafka |
| Broker (F9) | Recebe o `POST` em `/webhooks/message-created`, confere a assinatura com o mesmo segredo e responde 2xx só depois da confirmação do Kafka; 408, 429 e 5xx geram nova tentativa |
| Observabilidade (F14) | Usa a profundidade da fila `webhooks` e as falhas como métricas |
| Robustez e escala (F15) | Dimensiona threads, polling, pool, réplicas e heartbeat por medida |
| Experimento (F18) | Mata o `jobs-webhooks` com `docker kill`; a reconciliação da H3 considera a demora de 4 a 11 minutos da recuperação |

## Fontes

- `documents/arquitetura.md`, seções "Decisões de design", "Robustez" e "Ação com a conversa fora da IA"
- `documents/fases/04-contrato-de-integracao.md`, seções "Webhook `message.created`" e "Assinatura"
- `documents/fases/09-api-de-acoes-e-contexto.md`
- [Solid Queue · README (configuração, workers, dispatchers, polling e tarefas recorrentes)](https://github.com/rails/solid_queue)
- [Mission Control - Jobs · README](https://github.com/rails/mission_control-jobs)
- [Rails Guides · Active Job Basics (`retry_on`)](https://guides.rubyonrails.org/active_job_basics.html)
- Código das gems no contêiner: `solid_queue` 1.7.2 (`lib/solid_queue/cli.rb`, `lib/solid_queue/configuration.rb`, `app/models/solid_queue/process/executor.rb`, `app/models/solid_queue/process/prunable.rb`, `lib/solid_queue/supervisor/maintenance.rb` e `lib/solid_queue/fork_supervisor.rb`), `mission_control-jobs` 1.3.1 e `activejob` 8.1.4.1 (`lib/active_job/exceptions.rb`)

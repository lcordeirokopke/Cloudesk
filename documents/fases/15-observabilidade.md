# Cloudesk · Observabilidade

## O que é

A observabilidade torna visível cada salto de uma mensagem e mede as metas de volume. Ela é feita de:

- **métricas** no Prometheus: latência entrada → Kafka, latência por salto e ponta a ponta, Solid Queue (profundidade e fila de falhas por classe), TPS e conexões do Postgres, lag de consumo do Kafka e os indicadores do cockpit;
- **dois dashboards** no Grafana: "Cloudesk - Saltos e experimento" e "Cloudesk - Cockpit operacional" (diferencial 2), com seis alertas;
- **a linha do tempo por mensagem** no painel do analista, montada a partir de `audit_events` e do `trace_id`.

Nada disso instrumenta os caminhos quentes do Core. As latências saem dos carimbos que a cadeia já grava em `audit_events` e do horário da confirmação do Kafka no `broker-web`.

## Onde fica no fluxo

```text
Canal → web (received_at) → jobs-webhooks → broker-web (broker_received_at, ack do Kafka) → agent.inbound (kafka_appended_at)
      → agente (agent_consumed_at, ferramentas, agent_published_at) → broker-consumer → web (received_at da ação)
      → jobs-default → canal (delivered_at)

broker-web /metrics ─────────────────────┐
metrics /metrics (lê audit_events,       │
  solid_queue_*, conversas, handoffs) ───┼──→ Prometheus ──→ Grafana (dashboards e alertas)
redpanda /public_metrics (lag) ──────────┤
postgres-exporter /metrics ──────────────┘

painel /panel/conversations/:id/messages/:message_id/timeline ← audit_events do trace_id
```

## Por que existe e que valor gera

**Medir as hipóteses.** A H2 (entrada → Kafka com p95 < 300 ms) e a H4 (ponta a ponta com p95 < 1 s, descontada a latência artificial do agente) têm um histograma cada, com buckets que contêm as fronteiras das metas. A H1 (sem backlog crescente) é lida na profundidade do Solid Queue e no lag do Kafka.

**Achar o gargalo.** A latência ponta a ponta é decomposta em seis saltos, do Core ao Broker, ao Kafka, ao agente, de volta ao Core e ao canal. O p95 por salto mostra onde o tempo é gasto.

**Operar em tempo real.** O cockpit mostra a profundidade por fila, os casos em risco de SLA, a contenção da IA, os motivos de escalação, o lag, o backlog e a fila de falhas, com alertas, entre eles o de job na fila de falhas há mais de 2 minutos.

**Explicar uma mensagem.** A linha do tempo mostra, para uma mensagem do lojista, o horário de cada salto, a duração entre eles, as ferramentas do agente, a latência artificial, as ações aceitas e recusadas e a entrega, a partir de `audit_events`, sem serviço de tracing externo.

**Sem custo nos caminhos quentes.** O `metrics` lê o banco num processo à parte, e o `broker-web` só observa um valor depois da confirmação do Kafka. O Core não grava nada a mais.

## Como funciona

### Entrada → Kafka no `broker-web`

`Broker::WebhookApp` (`core/lib/broker/webhook_app.rb`) observa, logo depois do `produce_sync` confirmado, o tempo desde o `received_at` do corpo do webhook, que é o horário do recebimento HTTP no Core. O valor vai para `cloudesk_broker_inbound_latency_seconds{brand}`, só nas respostas `200`; um valor negativo, por diferença de relógio, é observado como 0. Cada resposta do `POST /webhooks/message-created` conta em `cloudesk_broker_webhooks_total{status}` (`200`, `401`, `422`, `503`).

O registro fica em `Broker::Metrics` (`core/lib/broker/metrics.rb`), um por processo, em memória. O `GET /metrics` do mesmo app serve o texto do Prometheus. O Broker continua sem Rails: o `core/lib/broker.rb` carrega a gem `prometheus-client` junto do Karafka.

### Serviço `metrics`

Processo próprio, da imagem do Core, com o Rails carregado (`core/metrics.ru`, `core/config/puma_metrics.rb`, Puma single com 1 thread, porta 9394 só na rede do Compose):

- `Observability::Registry` cria um `Prometheus::Client::Registry` próprio com todas as métricas do serviço;
- `Observability::Collector` abre uma thread de fundo que, a cada 5 s, chama os três leitores dentro do executor do Rails. O erro de um leitor é registrado em log e em `cloudesk_metrics_collect_errors_total{reader}` e não impede os outros; a duração de cada leitor vai para `cloudesk_metrics_collect_duration_seconds{reader}`;
- `Observability::App` serve `GET /metrics` e `GET /up`, com 404 no restante. O `GET /metrics` só serializa o registro.

O `metrics` só lê. Os gauges são substituídos inteiros a cada coleta: o leitor calcula o conjunto novo, e as séries da coleta anterior que não aparecem nele voltam a 0 (`Observability::Registry#replace`).

### Latência por salto e ponta a ponta

`Observability::LatencyReader` lê `audit_events` por cursor, um por marca, em `Tenancy.with_brand`:

1. O cursor começa no boot, com um UUID v7 do instante; a marca que aparece depois recebe o mesmo cursor quando é vista pela primeira vez. Não há leitura retroativa.
2. A cada coleta, lê em lotes de 1000 os `message.delivered` com `id` maior que o cursor e criados há mais de 10 s, e avança o cursor para o maior `id` lido. A margem existe porque o `id` UUID v7 é gerado na inserção, e uma transação com `id` menor pode confirmar depois de outra com `id` maior.
3. Conta só a primeira entrega de uma mensagem `ai`: a entrega repetida e as respostas do sistema e do analista ficam fora.
4. No `message.created` da resposta, lê o `in_reply_to_sequence`, acha a mensagem do lojista respondida e o `message.created` dela, cujo `received_at` é o início.
5. Acha o `agent.reply` do mesmo `trace_id` cujo `inbound_event_id` é o `event_id` desse `message.created`, e dele lê os carimbos da ação e o `received_at` do Core.

| `hop` | Cálculo |
| - | - |
| `core_to_broker` | `broker_received_at` menos o `received_at` do `message.created` do lojista, com a espera na fila `webhooks` |
| `broker_to_kafka` | `kafka_appended_at` menos `broker_received_at` |
| `kafka_to_agent` | `agent_consumed_at` menos `kafka_appended_at` |
| `agent` | `agent_published_at` menos `agent_consumed_at`, com a latência artificial |
| `agent_to_core` | `received_at` do `agent.reply` menos `agent_published_at` |
| `core_to_channel` | `delivered_at` menos o `received_at` do `agent.reply`, com a fila `channels` |

A ponta a ponta bruta (`cloudesk_end_to_end_raw_latency_seconds{channel}`) vai do `received_at` da mensagem do lojista ao `delivered_at` da resposta. A descontada (`cloudesk_end_to_end_latency_seconds{channel}`) subtrai `model.parameters.artificial_latency_ms` da ação. Sem o `agent.reply`, só a bruta é observada; sem `model`, os saltos e a bruta são observados, e a descontada não. Valor negativo é observado como 0 e registrado em log. As consultas usam os índices `(brand_id, id)`, `(brand_id, conversation_id)` e `(brand_id, trace_id)` de `audit_events`.

### Latência artificial do agente

O agente mock informa, em cada ação, quem decidiu e quanto esperou de propósito:

```json
"model": { "name": "agent-mock", "version": "0.1.0", "parameters": { "artificial_latency_ms": 500 } }
```

O `artificial_latency_ms` é a latência efetivamente aplicada antes da publicação: `AGENT_LATENCY_MS` mais o atraso do modo `delay`, quando ele vale para o evento (marcador ou configuração). A ação duplicada leva o mesmo `model`. O schema `action` já aceita o campo, e o Core grava a ação inteira no `agent.reply`.

### Solid Queue

`Observability::QueueReader` lê as tabelas `solid_queue_*`, fora do RLS, com consultas agrupadas:

| Métrica | Leitura |
| - | - |
| `cloudesk_solid_queue_jobs{queue,state}` | `ready`, `scheduled` e `claimed` por fila; toda fila vista recebe os três estados |
| `cloudesk_solid_queue_oldest_ready_age_seconds{queue}` | agora menos o `created_at` do job pronto mais antigo |
| `cloudesk_solid_queue_failed_jobs{class}` | jobs na fila de falhas por classe |
| `cloudesk_solid_queue_failed_oldest_age_seconds{class}` | agora menos o `created_at` da falha mais antiga |

### Cockpit

`Observability::CockpitReader` lê o domínio por marca, em `Tenancy.with_brand`, sem travas. O label `brand` é o slug da marca e o `queue` é o nome da fila (`none` sem fila).

| Métrica | Definição |
| - | - |
| `cloudesk_conversations_open{brand,queue,state}` | conversas em `with_ai`, `awaiting_human` e `with_human` |
| `cloudesk_conversations_sla{brand,queue,level}` | fração do SLA consumida: em `with_ai`, desde a última mensagem do lojista sem mensagem `ai` depois dela; em `awaiting_human`, desde `queued_at`. `at_risk` de 0,5 até menos de 1, `breached` a partir de 1 |
| `cloudesk_conversations_resolved_24h{brand}` | `conversation.resolved` das últimas 24 h |
| `cloudesk_conversations_resolved_by_ai_24h{brand}` | os de ator `ai` sem handoff da conversa criado antes do evento |
| `cloudesk_handoffs_24h{brand,reason}` | handoffs das últimas 24 h por motivo |

A leitura dos `conversation.resolved` usa, além da condição em `created_at`, um limite inferior pelo `id` UUID v7 (o instante de 24 h e 1 min atrás), para percorrer só o trecho recente do índice `(brand_id, id)`.

### Lag do Kafka

O `redpanda-init` liga o lag por grupo nas métricas nativas do Redpanda, a cada subida:

```text
rpk cluster config set enable_consumer_group_metrics '["group","partition","consumer_lag"]' -X admin.hosts=redpanda:9644
rpk cluster config set consumer_group_lag_collection_interval_sec 15 -X admin.hosts=redpanda:9644
```

O Prometheus lê `redpanda_kafka_consumer_group_lag_sum` e `redpanda_kafka_consumer_group_lag_max`, com o label `redpanda_group`, em `redpanda:9644/public_metrics`, a cada 15 s.

### Postgres

O `postgres_exporter` conecta ao banco `cloudesk_development` com o papel `cloudesk_monitor`. O papel é membro de `pg_monitor`, não tem `GRANT` em tabelas de domínio, não é superusuário nem tem `BYPASSRLS`. Ele é de cluster e fica fora do `db/structure.sql`: o serviço `postgres-monitor-init` roda `infra/postgres/monitor/create-monitor-role.sh` com o superusuário a cada subida, num bloco `DO` idempotente que cria o papel quando ele não existe, grava a senha de `DB_MONITOR_PASSWORD` e concede `pg_monitor`. Os dashboards usam `pg_stat_database_xact_commit`, `pg_stat_database_xact_rollback` e `pg_stat_activity_count{state}`.

### Prometheus

`infra/prometheus/prometheus.yml`, coleta e avaliação a cada 5 s:

| Job | Alvo |
| - | - |
| `metrics` | `metrics:9394` |
| `broker-web` | descoberta por DNS de `broker-web`, porta 3000, que encontra cada réplica |
| `redpanda` | `redpanda:9644/public_metrics`, a cada 15 s |
| `postgres` | `postgres-exporter:9187` |
| `prometheus` | o próprio |

### Dashboards

Os dois ficam na pasta "Cloudesk", provisionados de `infra/grafana/dashboards/`, com o datasource `prometheus` de `infra/grafana/provisioning/datasources/`.

"Cloudesk - Saltos e experimento" (`cloudesk-saltos`):

- p50, p95 e p99 entrada → Kafka, com a linha da meta de 0,3 s;
- p95 ponta a ponta descontada e bruta por canal, com a linha da meta de 1 s;
- p95 por salto, empilhado;
- taxa de entrada (webhooks `200`) e de respostas da IA entregues;
- Solid Queue por fila e estado, idade do pronto mais antigo, fila de falhas por classe e tempo da falha mais antiga;
- lag por grupo;
- transações por segundo e conexões por estado do Postgres;
- duração e erros da coleta do `metrics`.

"Cloudesk - Cockpit operacional" (`cloudesk-cockpit`, página inicial do Grafana, variável `brand`):

- contenção da IA nas últimas 24 h, em percentual (`resolved_by_ai_24h` sobre `resolved_24h`);
- casos em risco e vencidos, em números e em barras por fila;
- profundidade por fila (`with_ai` e `awaiting_human`);
- Pareto dos motivos de escalação: barras do maior para o menor e percentual acumulado, pelas transformações `merge`, `sortBy`, `calculateField` (`cumulativeFunctions`) e `organize`;
- lag do Kafka, backlog do Solid Queue e fila de falhas por classe;
- lista de alertas.

### Alertas

`infra/grafana/provisioning/alerting/cloudesk-alerts.yml`, grupo `cloudesk`, avaliado a cada 10 s. Cada regra lê a expressão no Prometheus, reduz ao último valor descartando valores não numéricos e compara com o limite. Sem dado, o alerta fica normal (`noDataState: OK`), e o p95 sem tráfego conta como sem dado. Os alertas aparecem só na interface do Grafana, sem notificação externa.

| Alerta | Expressão | Limite | Pendente por |
| - | - | - | - |
| Job na fila de falhas há mais de 2 min | `max(cloudesk_solid_queue_failed_oldest_age_seconds)` | 120 | 0 s |
| Lag do Kafka alto | `max(redpanda_kafka_consumer_group_lag_sum{redpanda_group=~"cloudesk-agent\|cloudesk-broker"})` | 1000 | 2 min |
| Backlog do Solid Queue alto | `max(cloudesk_solid_queue_jobs{state="ready", queue=~"webhooks\|channels"})` | 1000 | 2 min |
| p95 entrada → Kafka acima da meta | `histogram_quantile(0.95, sum by (le) (rate(cloudesk_broker_inbound_latency_seconds_bucket[5m])))` | 0,3 | 5 min |
| p95 ponta a ponta acima da meta | `histogram_quantile(0.95, sum by (le) (rate(cloudesk_end_to_end_latency_seconds_bucket[5m])))` | 1 | 5 min |
| Casos em risco de SLA | `sum(cloudesk_conversations_sla)` | 0 | 1 min |

Os limites ficam no início do arquivo, comentados, e no `params` de cada regra.

### Linha do tempo por mensagem

No histórico da conversa no painel, cada mensagem do lojista tem o link "Linha do tempo", que abre `GET /panel/conversations/:conversation_id/messages/:message_id/timeline` (`Panel::TimelinesController`). A página roda no `in_brand` do painel e responde 404 quando a conversa não é da marca do analista ou a mensagem não é do lojista nessa conversa.

`Conversations::MessageTimeline.for(message)` só lê. A partir do `message.created` da mensagem:

| Passo | Horário | Detalhe |
| - | - | - |
| Canal → Core | `received_at` do `message.created` | canal |
| Core → Broker | `broker_received_at` | |
| Kafka | `kafka_appended_at` | |
| Agente consumiu | `agent_consumed_at` | |
| Ferramenta `<nome>`, uma linha por ferramenta | `started_at` | horário do `finished_at` |
| Agente publicou | `agent_published_at` | latência artificial, quando há `model` |
| Broker → Core, uma linha por ação | `received_at` do `agent.<tipo>`, `agent.action.stale` ou `agent.action.rejected` | tipo da ação ou a recusa |
| Cliente | `delivered_at` da primeira entrega da resposta `ai` com `in_reply_to_sequence` igual à `sequence` da mensagem | |

Os carimbos vêm da primeira ação cujo `inbound_event_id` é o `event_id` do `message.created`. Sem ação, a página para no primeiro passo e diz que não há ação do agente para a mensagem. A tabela de saltos mostra o horário em milissegundos no fuso da equipe do analista, a duração desde o passo anterior e o total desde a entrada; a tabela de eventos lista todos os `audit_events` do mesmo `trace_id`, com ação, ator, horário e motivo; o `trace_id` aparece no topo.

## O que o sistema garante

- A latência entrada → Kafka é observada só depois da confirmação do Kafka e só nas respostas `200` do `broker-web`.
- Cada resposta da IA entra uma vez na latência ponta a ponta, mesmo com a entrega repetida.
- A latência descontada subtrai a latência artificial que o próprio agente informou para aquela ação.
- O `metrics` não grava nada no banco, lê o domínio sempre dentro de `Tenancy.with_brand` e não mistura as marcas.
- O erro de um leitor não interrompe os outros nem o `/metrics`.
- Uma série de gauge que deixa de existir volta a 0 na coleta seguinte.
- O papel de monitoração do Postgres não lê tabelas de domínio.
- Sem dado, nenhum alerta dispara.
- A linha do tempo só abre mensagens do lojista de conversas da marca do analista.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Rastreabilidade e auditoria | Linha do tempo por mensagem no painel a partir de `audit_events` e `trace_id` | Carimbos do Broker (F9) e do agente (F10), gravação da ação no `audit_event` (F8) |
| Painel do analista | Link e página da linha do tempo | Fila, conversa e ações (F11) |
| Diferencial 2 | Cockpit com indicadores e alertas | Escalações e motivos (F11), SLA e timeout (F11) |
| Agente mock | `model` com `artificial_latency_ms` em cada ação | Decisão, ferramentas e modos de falha (F10) |
| Experimento técnico | Métricas e dashboard das hipóteses | Carga, falhas e análise (F18) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min sem backlog crescente | `cloudesk_solid_queue_jobs`, `cloudesk_solid_queue_oldest_ready_age_seconds` e o lag dos grupos `cloudesk-agent` e `cloudesk-broker` ao longo do tempo |
| H2 · entrada → Kafka com p95 < 300 ms | p95 de `cloudesk_broker_inbound_latency_seconds`, com o bucket de 0,3 s |
| H3 · nada perdido nem duplicado | A linha do tempo e os eventos do trace mostram cada ação e cada entrega de uma mensagem; a reconciliação é da F18 |
| H4 · ponta a ponta com p95 < 1 s, descontada a latência artificial | p95 de `cloudesk_end_to_end_latency_seconds` por canal, com o bucket de 1 s, ao lado da bruta e do p95 por salto |

As métricas do Prometheus servem para acompanhar a execução. Os valores exatos da análise saem de `audit_events`, que guarda todos os carimbos.

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 2 · Cockpit operacional | O dashboard inteiro: profundidade por fila, risco de SLA, contenção da IA, Pareto, lag, backlog, fila de falhas e alertas |
| 4 · Modos de falha do agente mock | O atraso do modo `delay` entra em `artificial_latency_ms` e é descontado da ponta a ponta; a ação recusada aparece na linha do tempo |
| 3 · "Por que caiu aqui?" | A linha do tempo complementa a explicação do roteamento com o caminho da mensagem pelo sistema |

## Limitações

- **Uma réplica do `metrics`.** O cursor fica na memória do processo. Ao reiniciar, o serviço perde as contagens dos histogramas e o cursor e volta a contar a partir do boot, sem as entregas do intervalo.
- **Atraso de 10 s nas latências.** A margem do cursor faz a latência de uma entrega aparecer no Prometheus cerca de 10 s depois dela. Uma transação do Core mais longa que 10 s pode ficar fora da contagem.
- **Precisão dos histogramas.** O p95 do Prometheus é interpolado dentro do bucket. O valor exato sai de `audit_events`.
- **Relógios.** Os saltos comparam carimbos de processos diferentes. No ambiente local, todos usam o relógio da mesma máquina; um valor negativo é observado como 0.
- **Lag sem partição.** O lag é lido por grupo, sem o detalhe por partição.
- **Alertas só na interface.** Não há notificação por e-mail, Slack ou outro canal.
- **`/metrics` sem autenticação.** Alcançável na rede do Compose; o do `broker-web` sai pela porta 3001 do host.
- **Leituras recorrentes no banco.** A cada 5 s, o `metrics` lê `audit_events`, as tabelas do Solid Queue, as conversas abertas e os handoffs das últimas 24 h.

## Operação

### Processos

| Serviço | Comando ou imagem | Porta no host |
| - | - | - |
| `metrics` | `bundle exec puma -C config/puma_metrics.rb metrics.ru`, imagem `cloudesk-core:dev`, `RAILS_MAX_THREADS=2` | nenhuma (9394 na rede do Compose) |
| `postgres-monitor-init` | `postgres:18`, `create-monitor-role.sh`; roda e termina | nenhuma |
| `postgres-exporter` | `ghcr.io/prometheus-community/postgres-exporter:v0.21.1` | nenhuma (9187 na rede do Compose) |
| `prometheus` | `prom/prometheus:v3.16.0` | `9090` |
| `grafana` | `grafana/grafana:13.3.1` | `3002` |

O `postgres-exporter` sobe depois do `postgres-monitor-init` concluído. Os volumes `prometheus-data` e `grafana-data` guardam a série histórica e o banco do Grafana.

### Configuração

| Variável | Uso | Valor |
| - | - | - |
| `DB_MONITOR_USERNAME` | Papel de monitoração do Postgres | `.env`, padrão `cloudesk_monitor` |
| `DB_MONITOR_PASSWORD` | Senha do papel de monitoração | `.env` |
| `GRAFANA_ADMIN_USER` | Administrador do Grafana | `.env` |
| `GRAFANA_ADMIN_PASSWORD` | Senha do administrador do Grafana | `.env` |

O Grafana tem acesso anônimo com o papel `Viewer`.

### Inspeção

```text
curl -s localhost:9090/api/v1/query --data-urlencode 'query=cloudesk_hop_latency_seconds_count'
curl -s localhost:3001/metrics
docker compose exec redpanda rpk cluster config get enable_consumer_group_metrics
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/broker/webhook_app_spec.rb` | `GET /metrics` em texto do Prometheus; o `200` observa a latência com a marca e o valor do ack menos o `received_at`; `401`, `422` e `503` contam e não observam latência |
| `core/spec/broker/isolation_spec.rb` | O Broker carrega sem Rails com a gem `prometheus-client` |
| `core/spec/modules/observability/latency_reader_spec.rb` | Os seis saltos, a bruta e a descontada numa cadeia completa; entrega repetida conta uma vez; respostas do sistema e do analista ficam fora; sem `model`, sem descontada; margem de 10 s; cursor por marca; entrega anterior ao leitor fora; salto negativo como 0 com log |
| `core/spec/modules/observability/queue_reader_spec.rb` | Contagens por fila e estado, idade do pronto mais antigo, falhas por classe e idade da mais antiga, séries que voltam a 0 |
| `core/spec/modules/observability/cockpit_reader_spec.rb` | Abertas por fila e estado; `at_risk` e `breached` em `with_ai` e `awaiting_human`; contenção; Pareto; séries que voltam a 0; marcas separadas |
| `core/spec/modules/observability/collector_spec.rb` | O erro de um leitor não para os outros e conta em `cloudesk_metrics_collect_errors_total`; os três leitores reais coletam sem erro |
| `core/spec/modules/observability/app_spec.rb` | `GET /metrics` com todas as famílias, `GET /up` e 404 |
| `core/spec/modules/conversations/message_timeline_spec.rb` | Passos em ordem com os carimbos, a ferramenta e a entrega; ação recusada no passo do Broker → Core; sem ação, só o primeiro passo |
| `core/spec/requests/panel/timelines_spec.rb` | Página com os saltos e o `trace_id`; link só nas mensagens do lojista; 404 para mensagem do atendente, de outra conversa e de outra marca; basic auth e sessão do painel |
| `agent_mock/tests/test_processor.py`, `agent_mock/tests/test_action.py` | `model` com `name`, `version` e `artificial_latency_ms` igual a `AGENT_LATENCY_MS`, somado ao atraso do `delay` por configuração e por marcador; ação duplicada com o mesmo `model`; ação válida no schema |

No Compose:

- `metrics`, `prometheus`, `grafana` e `postgres-exporter` em execução; `postgres-monitor-init` e `redpanda-init` concluídos com código 0;
- `enable_consumer_group_metrics` com `consumer_lag`, e as séries `redpanda_kafka_consumer_group_lag_sum` e `_max` dos grupos `cloudesk-agent` e `cloudesk-broker`;
- os cinco alvos do Prometheus com `health` `up` e o `promtool check config` com `SUCCESS`;
- com o cenário `reply` do simulador, `cloudesk_end_to_end_raw_latency_seconds_count`, `cloudesk_end_to_end_latency_seconds_count` e `cloudesk_broker_inbound_latency_seconds_count` passam de 0, e `cloudesk_hop_latency_seconds_count` tem os seis `hop`;
- com `AGENT_LATENCY_MS=500`, a bruta da resposta fica 0,500 s acima da descontada;
- com o cenário `handoff`, aparecem `cloudesk_handoffs_24h` e `cloudesk_conversations_open{state="awaiting_human"}`; com o SLA de demonstração de 1 minuto e o cenário `failure-drop`, a fila da conversa mostra `at_risk` e depois `breached` em `cloudesk_conversations_sla`, e o alerta "Casos em risco de SLA" fica em disparo;
- com `BROKER_WEBHOOK_URL` numa rota 404 do `broker-web`, o `Agents::WebhookDeliveryJob` vai à fila de falhas, `cloudesk_solid_queue_failed_jobs{class="Agents::WebhookDeliveryJob"}` passa a 1 e, depois de 2 minutos, o alerta "Job na fila de falhas há mais de 2 min" fica em disparo;
- no Grafana, os dois dashboards na pasta "Cloudesk", o cockpit como página inicial e as seis regras em "Alerting";
- no painel, a linha do tempo de uma mensagem do cenário `reply` mostra os oito passos, a linha da ferramenta, os horários e as durações, e os eventos do mesmo `trace_id`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco e auditoria (F1, F2) | `audit_events` com `trace_id`, envelope e índices `(brand_id, id)`, `(brand_id, conversation_id)` e `(brand_id, trace_id)`; `Tenancy.with_brand` |
| Contrato (F3) | Campo `model` e `timestamps` do schema `action`; `received_at` do webhook |
| Saída para o Broker (F7) | Fila `webhooks` dentro do salto `core_to_broker`; falha permanente do webhook na fila de falhas |
| API de ações (F8) | `agent.reply` com a ação inteira e o `received_at` do Core |
| Broker (F9) | `broker_received_at`, histograma entrada → Kafka e lag do grupo `cloudesk-broker` |
| Agente mock (F10) | Carimbos do agente e `model.parameters.artificial_latency_ms` |
| Handoff, painel e timeout (F11) | SLA, handoffs, motivos e a página da linha do tempo no painel |
| Robustez e escala (F15) | Réplicas do `broker-web` encontradas pela descoberta por DNS do Prometheus |
| Experimento técnico (F18) | Dashboard das hipóteses e limites dos alertas |

## Fontes

- `documents/arquitetura.md`, seções "Auditoria e rastreabilidade", "Observabilidade", "Experimento técnico" e "Diferenciais"
- `documents/fases/04-contrato-de-integracao.md`, seções "Horário de gravação no Kafka" e "Ação do agente"
- `documents/fases/10-broker.md`, seção "Ida: webhook para o Kafka"
- `documents/fases/11-agente-mock.md`, seções "Um evento, do consumo à publicação" e "A ação publicada"
- `documents/fases/12-handoff-painel-e-timeout.md`, seções "Timeout do agente", "Painel do analista" e "SLA de demonstração"
- Código da gem `prometheus-client` 5.0.0: `Prometheus::Client::Registry`, `Histogram`, `Gauge`, `Counter` e `Prometheus::Client::Formats::Text`
- Métricas expostas pelo Redpanda v26.2.7 em `/public_metrics` e pelo `postgres_exporter` v0.21.1 em `/metrics`, conferidas nos contêineres

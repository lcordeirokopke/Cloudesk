# Cloudesk · Robustez e escala

## O que é

Esta parte prepara a plataforma para a meta de volume e para falhas, sem trocar a arquitetura: um código, uma imagem, um Postgres. Ela reúne seis peças:

- **Escala por réplica.** `web`, `jobs-webhooks`, `broker-web`, `broker-consumer` e `agent-mock` escalam pelo número de réplicas no Compose (`docker compose up -d --scale <serviço>=<N>`). O `web` fica atrás de um balanceador nginx, o `web-lb`.
- **Dimensionamento.** Cada réplica tem um processo, o pool de conexões de cada processo é o `RAILS_MAX_THREADS` dele e o `max_connections` do Postgres cobre a soma dos processos. Os valores são medidos com um roteiro próprio.
- **Heartbeat do Solid Queue.** O processo morto é detectado em 30 s, e o webhook interrompido volta à fila em cerca de 30 a 75 s.
- **Limite de taxa por marca.** O WhatsApp e a entrada JSON do chat recusam com `429` o que passa do limite por segundo de cada marca. O formulário do widget de chat tem limite próprio, por lojista e por marca.
- **Índices parciais.** Três índices para as consultas recorrentes sobre conversas abertas.
- **Reprocessamento da DLQ.** A tela `/admin/dlq` lista as ações em `agent.dlq` e as devolve a `agent.outbound`, uma por vez, com auditoria.

A conferência `bin/rails robustness:check` prova, depois de uma rodada com réplicas ou com falhas, que nenhuma resposta, entrega ou ação foi duplicada e que toda mensagem enviada ao agente teve ação.

## Onde fica no fluxo

```text
Canais, navegador, agente, broker-consumer
        │  HTTP e WebSocket, porta 3000
        ▼
     web-lb (nginx) ──► web × N ──► Postgres ◄── jobs-webhooks × N ──► broker-web × N ──► agent.inbound
                         │                                                  ▲
                         │  /admin/dlq: GET e POST assinados                 │ lê agent.dlq e
                         └──────────────────────────────────────────────────┘ republica em agent.outbound
```

O limite de taxa fica na entrada do `web`, antes do `Conversations::Intake`. A DLQ continua só no Broker: o Core a lê e a republica por HTTP assinado, sem cliente Kafka.

## Por que existe e que valor gera

**Volume sem redesenho.** As metas de 80 msg/s no pico e 250 msg/s sustentados exigem mais de um processo por papel. Com réplicas, cada papel cresce pela sua carga, e a correção não muda: a deduplicação continua no Core (`processed_events`), a ordem continua decidida pelo estado e o Solid Queue distribui os jobs entre os workers com `FOR UPDATE SKIP LOCKED`.

**Recuperação em segundos.** O heartbeat padrão do Solid Queue (60 s e limiar de 5 min) deixa os webhooks de um worker morto presos por 4 a 11 minutos. Com 5 s e 30 s, o webhook volta à fila em cerca de 30 a 75 s, o que encurta o atraso das mensagens afetadas na H3.

**Proteção por marca.** Um pico ou um cliente com defeito em uma marca não ocupa a capacidade da outra: o limite é contado por marca, e a recusa sai antes de qualquer escrita de domínio.

**Ação perdida recuperável.** Uma ação que vai à DLQ (Core fora do ar por mais de 10 tentativas, recusa permanente) volta ao fluxo pela operação, com registro de quem reprocessou e de onde para onde, sem risco de efeito duplicado.

## Como funciona

### Balanceador e réplicas

O `web-lb` (`nginx:1.30.8-alpine`, `infra/nginx/nginx.conf`) publica a porta 3000 no host e na rede do Compose. O `web` e o `broker-web` não publicam porta.

| Ponto | Configuração |
| - | - |
| Descoberta das réplicas | `upstream web { zone web 64k; server web:3000 resolve; keepalive 32; }` com `resolver 127.0.0.11 valid=5s`: o nginx resolve o nome `web` pelo DNS do Docker a cada 5 s, e as réplicas novas entram sem reinício |
| WebSocket do Action Cable | `proxy_http_version 1.1`, `Upgrade` e `Connection` pelo `map $http_upgrade $connection_upgrade`, `proxy_read_timeout 3600s` |
| `Host` | `$http_host`, com a porta: o Action Cable aceita a conexão quando o `Origin` é igual a `http://<Host>`, e os redirects do Rails usam a porta |
| Corpo | `client_max_body_size 1m`: os canais mandam só JSON e metadados de anexo |
| Log | `access_log off`: o salto do balanceador fica fora da medida, e o `received_at` continua sendo o do `TraceContextMiddleware` |

Agente (`CORE_URL`), Broker (`CORE_ACTIONS_URL`), simulador (`CORE_URL`, `CORE_CABLE_URL`, `CORE_ORIGIN`) e Mailpit (`MP_WEBHOOK_URL`) chamam o Core por `http://web-lb:3000`, e `config.hosts` aceita `web-lb`. O Puma do `web` grava o pid em `/tmp/server.pid`, dentro do contêiner: o caminho padrão (`tmp/pids/server.pid`) fica no volume do código, compartilhado pelas réplicas.

O `broker-web` é alcançado pelo DNS do Compose, que devolve os endereços de todas as réplicas do serviço, e o Prometheus encontra cada uma pela descoberta por DNS. O `broker-consumer` e o `agent-mock` dividem as 6 partições dos tópicos entre as réplicas pelo grupo de consumo.

### Dimensionamento

| Peça | Valor |
| - | - |
| Puma do `web` | Modo single, `RAILS_MAX_THREADS` igual a `WEB_MAX_THREADS` (padrão 3) |
| Workers do Solid Queue | `processes: 1` em `config/queue.yml` e `config/queue_webhooks.yml`; o serviço escala por réplica |
| Pool de cada processo | `RAILS_MAX_THREADS` do processo (`config/database.yml`) |
| `max_connections` do Postgres | `POSTGRES_MAX_CONNECTIONS` (padrão 200), por `command: postgres -c max_connections=...` |
| Perfil de carga | `CLOUDESK_LOAD_PROFILE=1`: sem recarregamento, `eager_load`, log `info`, sem `server_timing`, logs verbosos e anotações de view |

Medida com `experiment/scale/measure_idle.sh`, perfil de carga ligado, banco `cloudesk_development`. TPS é `rate(pg_stat_database_xact_commit[1m])`; conexões, `pg_stat_activity_count`, ambos do `postgres-exporter`. Com os serviços ociosos, depois de 2 min em cada configuração:

| Réplicas | TPS | Conexões |
| - | - | - |
| `jobs-webhooks` 1, `jobs-default` 1 | 65,4 | 19 |
| `jobs-webhooks` 2, `jobs-default` 1 | 85,8 | 24 |
| `jobs-webhooks` 4, `jobs-default` 1 | 126,8 | 34 |
| `jobs-webhooks` 1, `jobs-default` 2 | 89,5 | 32 |
| `jobs-webhooks` 1, `jobs-default` 4 | 139,4 | 54 |

Cada réplica ociosa do `jobs-webhooks` (worker `webhooks` com polling de 0,1 s, dispatcher de 1 s e heartbeat de 5 s) custa cerca de 20 TPS e 5 conexões. Cada réplica ociosa do `jobs-default` (workers `channels` com 0,1 s e `default` com 1 s, dispatcher, scheduler e as tarefas recorrentes) custa cerca de 24 TPS e 12 conexões. O polling de 0,1 s é o maior custo ocioso, e ele cresce linear com as réplicas.

Carga leve: `send --channel all --count 4800 --rate 80` com `web`, `jobs-webhooks`, `broker-web`, `broker-consumer` e `agent-mock` em 2 réplicas.

| Medida | Valor |
| - | - |
| Máximo de conexões | 36 |
| TPS máximo (janela de 1 min) | 307 |
| Máximo de lag (soma dos grupos) | 123 |
| Espera máxima na fila `webhooks` | 0,09 s |
| Espera máxima na fila `channels` | 0,13 s |
| Máximo de jobs prontos | 692, todos do e-mail: `action_mailbox_routing` (até 677 jobs e 143 s de espera) e `default` (até 479, ingestão) |
| `robustness:check` desde o início da carga | `ok` nas quatro linhas |

Conexões por contêiner ao fim da carga: `web` 3 por réplica, `jobs-webhooks` 6 por réplica, `jobs-default` 16, `metrics` 1, `postgres-exporter` 1.

Conta de conexões para a configuração da carga, pelo máximo medido de cada processo e pelo teto do pool do `jobs-webhooks` (worker de 5 threads mais 2, dispatcher e supervisor, cerca de 10): `3 × web + 10 × jobs-webhooks + 16 (jobs-default) + 2 (metrics) + 1 (postgres-exporter)`. Com 4 réplicas de `web` e 4 de `jobs-webhooks`, cerca de 71; com 8 e 8, cerca de 123. O `max_connections` de 200 cobre as duas com margem para migrações, consoles e o `robustness:check`. Os workers `webhooks` e `channels` esperaram no máximo 0,13 s na carga, sem pedir mais threads; `WEB_MAX_THREADS` fica em 3, e as threads e o polling das filas ficam como estão. O backlog do e-mail fica fora da carga do experimento, que usa só WhatsApp e chat.

### Heartbeat do Solid Queue e worker morto

`config/application.rb` define `process_heartbeat_interval` em 5 s e `process_alive_threshold` em 30 s. Na gem `solid_queue` 1.7.2, a manutenção de cada supervisor roda a cada `process_alive_threshold` e remove os processos sem heartbeat há mais de 30 s; os jobs em execução neles vão à fila de falhas com `ProcessPrunedError`. A tarefa `recover_interrupted_webhooks` (`config/recurring.yml`) roda a cada 15 s e devolve os webhooks à fila.

| Trecho | Esperado | Medido com `docker kill` |
| - | - | - |
| Morte até a remoção do processo | 30 a 60 s (último heartbeat até 5 s antes, limiar de 30 s, manutenção a cada 30 s) | 28 s |
| Morte até a fila de falhas dos webhooks vazia | até cerca de 75 s | 62 s |

Na medida, o `broker-web` ficou pausado por alguns segundos para que a réplica morresse com webhooks em execução: 5 jobs foram para a fila de falhas e voltaram pela `recover_interrupted_webhooks` ("webhooks interrompidos devolvidos à fila: 5"). Sem webhook em execução no instante da morte, o processo é removido do mesmo jeito (30 s na primeira rodada), e nada vai à fila de falhas.

### Limite de taxa por marca

`brands.inbound_rate_limit_per_second` é um inteiro com padrão 500 e `CHECK` maior que 0, sem edição no admin. `Channels::RateLimit.check(counts, channel:)`:

1. recebe a contagem de mensagens da requisição por marca;
2. para cada marca, incrementa `inbound_rate:<brand_id>:<segundo>` no Solid Cache (`Rails.cache.increment`), uma janela fixa de 1 s;
3. devolve recusa na primeira marca cujo total passa do limite, com marca, contagem e limite, e grava a recusa no log.

O controller de WhatsApp conta as mensagens do payload por marca; se alguma marca passa do limite, o payload inteiro recebe `429` com `Retry-After: 1` e `{"error": "rate_limited"}`, e nada é gravado. Os incrementos das marcas já contadas no mesmo payload ficam: o contador mede tentativas na janela. O controller de chat conta uma mensagem da marca do corpo. A recusa não grava `audit_event`, porque sai antes do `Conversations::Intake`, sem escrita de domínio.

Contador indisponível (`increment` nulo: null store, como no ambiente de teste, ou erro do cache) deixa a mensagem passar e grava um aviso no log. As chaves não expiram; as antigas saem pelo `max_size` do Solid Cache (256 MB). O e-mail fica fora do limite: não entra na carga do experimento, e o e-mail perdido pelo webhook é trazido pela `sweep_mailpit`.

**Widget de chat.** O formulário passa por `Channels::RateLimit.check_widget(brand, contact)`, com dois contadores próprios no Solid Cache, de valores iguais para todas as marcas:

| Ordem | Contador | Limite | `Retry-After` |
| - | - | - | - |
| 1 | `widget_rate:<brand_id>:contact:<contact_id>:<janela>`, janela fixa de 10 s | 5 mensagens por lojista | Segundos até a janela seguinte |
| 2 | `widget_rate:<brand_id>:<segundo>`, janela fixa de 1 s | 10 mensagens por segundo do widget na marca | `1` |

- **Separados do limite da marca.** O contador da marca mede tentativas, e o widget é a entrada mais aberta: exige só um lojista escolhido na tela. Com contadores próprios, um abuso no widget não consome a cota do WhatsApp nem da entrada JSON, e o limite da marca não recusa o widget.
- **O lojista primeiro.** A linha do contador do lojista é disputada só por ele. A recusa por lojista custa um incremento e não chega à linha do widget da marca nem ao `Conversations::Intake`; o envio que passa pelo lojista custa dois.
- **Pelo `contact.id`.** Uma sessão nova do mesmo lojista continua na mesma contagem.
- **O teto por marca.** As duas marcas somam 20 mensagens por segundo, abaixo dos 24 msg/s da H3 (`documents/fases/18-experimento-tecnico.md`).
- **Tentativas.** O reenvio do mesmo `client_message_id` conta; a mensagem vazia é recusada antes e não conta.

Na recusa, o controller só lê o histórico e responde a tela da conversa com `429`, `Retry-After`, o aviso "Muitas mensagens em pouco tempo" com os segundos de espera e o texto digitado no campo. Não há mensagem, `audit_event` nem job; o log leva a marca e o id do lojista, sem nome nem identidade. O Turbo renderiza a resposta e mantém a URL da conversa. O contador indisponível deixa passar, como no limite da marca.

### Índices parciais

| Índice | Definição | Consulta |
| - | - | - |
| `index_conversations_with_ai` | `conversations (brand_id) WHERE state = 'with_ai'` | Varredura do timeout do agente e cockpit |
| `index_messages_customer_by_sequence` | `messages (brand_id, conversation_id, sequence DESC) WHERE author = 'customer'` | Última mensagem do lojista de cada conversa (`LATERAL` da varredura e do cockpit) |
| `index_conversations_with_human_by_attendant` | `conversations (brand_id, attendant_id) WHERE state = 'with_human'` | Capacidade do analista no `Routing::Distributor` |

Os três são criados com `algorithm: :concurrently` (migração com `disable_ddl_transaction!`), sem travar a escrita.

`EXPLAIN` no banco de desenvolvimento, marca `infinitepay`, com 53 conversas (27 em `with_ai`) e 140 mensagens:

| Consulta | Plano |
| - | - |
| Varredura do timeout | `Seq Scan on conversations` e `Index Scan using index_messages_customer_by_sequence` no `LATERAL` |
| Capacidade do `Distributor` | `Index Only Scan using index_conversations_with_human_by_attendant` |

Com metade das conversas em `with_ai`, ler `conversations` inteira custa menos que o índice, e o planejador não usa o `index_conversations_with_ai`; com `enable_seqscan = off`, ele passa a `Bitmap Index Scan` no índice. Para o cenário em que o índice existe (conversas encerradas acumuladas e `with_ai` como fração pequena), a medida simula o volume numa transação desfeita no fim: 20.000 conversas `closed` sintéticas na marca, `ANALYZE` e `EXPLAIN ANALYZE` da varredura, com o papel dono. O planejador escolhe `Index Scan using index_conversations_with_ai`, e a varredura roda em 0,42 ms. O `ROLLBACK` desfaz as linhas e as estatísticas (53 conversas antes e depois).

### Reprocessamento da DLQ

```text
/admin/dlq ──► Admin::DlqClient ── GET /dlq/messages?brand=<slug>&limit=50 ──► Broker::DlqEndpoints ──► Broker::DlqReader ──► agent.dlq
"Reprocessar" ─► Admin::DlqReprocessor ── POST /dlq/messages/<p>/<o>/reprocess ──► republica em agent.outbound
                      │ 200
                      ▼
               dlq.reprocessed (Audit::Command)
```

**No Broker.** `Broker::WebhookApp` encaminha as rotas `/dlq/messages` a `Broker::DlqEndpoints`, que confere a assinatura com `BROKER_DLQ_SECRET` (método, caminho com a query string e corpo, janela de 300 s).

| Rota | Resposta |
| - | - |
| `GET /dlq/messages?brand=<slug>&limit=<n>` | `200 {messages}`: as últimas `limit` mensagens de cada partição de `agent.dlq` (padrão 50, de 1 a 500) com o header `brand` igual ao slug, por `dlq_failed_at` decrescente, até `limit` no total; cada uma com partição, offset, chave, headers, valor e, quando o valor é JSON, o tipo e o `inbound_event_id` da ação |
| `POST /dlq/messages/<partition>/<offset>/reprocess`, corpo `{"brand": "<slug>"}` | `200 {source, destination, diagnostics}`: a mensagem republicada em `agent.outbound` com a mesma chave, o mesmo valor byte a byte e os headers originais sem os de diagnóstico (lista do schema `kafka.dlq-headers`) |
| Erros | `401 invalid_signature` ou `expired_timestamp`; `404 not_found` sem mensagem na posição; `422 brand_mismatch` com o header `brand` diferente do corpo; `422 invalid_payload` com marca, limite ou corpo inválido; `503 kafka_unavailable` sem resposta do Kafka na leitura ou na publicação |

`Broker::DlqReader` lê o tópico com o `Karafka::Admin` e a configuração Kafka própria (endereços e `client.id` `cloudesk-broker-web`), sem configurar o `Karafka::App`: cada leitura abre um consumidor por `assign`, sem grupo de consumo e sem offset confirmado. A republicação usa o produtor do `broker-web` (`BROKER_PRODUCER`, `acks=all`), que escolhe a partição pelo particionador `murmur2_random` do librdkafka: o murmur2 da chave, a mesma fórmula do produtor `aiokafka` do agente e do `rpk`. A ação republicada cai na partição de `agent.outbound` em que o agente publica as ações da conversa, e o `broker-consumer` a processa em ordem com elas.

**No Core.** `Admin::DlqClient` chama o Broker em `BROKER_DLQ_URL` com conexão nova por chamada (2 s de conexão, 10 s de leitura) e o `traceparent` da requisição; erro de rede ou status diferente de 200 levanta `Admin::DlqClient::Error`. `Admin::DlqReprocessor`:

1. acha a mensagem na listagem da marca, o mesmo conjunto que a tela mostra;
2. recusa com `Admin::NotAllowed`, sem chamar o Broker, a mensagem sem `brand` ou de outra marca, com `dlq_reason` `invalid_message` ou com chave que não é o id de uma conversa da marca;
3. pede a republicação, fora de transação;
4. com o `200`, grava `dlq.reprocessed` pelo `Audit::Command`: ator `operator`, `actor_id` nulo, alvo e conversa a conversa da chave, sem webhook e sem atualização do painel; payload com `source` e `destination` (tópico, partição e offset), `dlq_reason`, `dlq_status`, `dlq_failed_at` e `operator_name`.

A tela mostra, por mensagem, posição, motivo, status, horário da falha, chave, tipo da ação, `inbound_event_id`, os reprocessamentos anteriores (horário, operador e destino) e o botão, desabilitado com o motivo quando a mensagem não pode ser reprocessada. Erro do Broker na listagem aparece na página, sem `500`. A mesma mensagem pode ser reprocessada de novo: cada republicação grava um evento, e a ação republicada segue o fluxo normal do `broker-consumer`. Uma ação já aplicada recebe `200 accepted` do Core com o resultado guardado; uma ação que falha de novo volta à DLQ em outro offset.

### Conferência de robustez

`bin/rails robustness:check SINCE=<ISO 8601>` (`core/lib/tasks/robustness.rake`, módulo `RobustnessCheck`) só lê, por marca, em `Tenancy.with_brand`, a partir de `SINCE`:

| Expectativa | Como confere |
| - | - |
| Nenhuma resposta `ai` duplicada | No máximo um `agent.reply` por `inbound_event_id` (o `event_id` do `message.created` do lojista) |
| Nenhuma entrega duplicada | No máximo um `message.delivered` por mensagem `ai` ou `system` |
| Nenhuma idempotência repetida | No máximo um evento de ação aceita (`agent.reply`, `agent.escalate`, `agent.categorize`, `agent.resolve`) por `idempotency_key` |
| Mensagens sem ação | Toda mensagem do lojista enviada ao agente tem ação aceita, `stale` ou `rejected` da conversa com `based_on_sequence` maior ou igual à `sequence` dela, ou escalação `ai_timeout` depois dela |

Mensagem enviada ao agente é a que tem o `event_id` do `message.created` em um `Agents::WebhookDeliveryJob` de `solid_queue_jobs` (o Solid Queue guarda os jobs concluídos; em produção, a tarefa `clear_solid_queue_finished_jobs` apaga os concluídos há mais de 1 dia, e a conferência vale para um `SINCE` dentro desse prazo) e não tem `webhook.skipped`. Uma ação sobre uma mensagem mais nova cobre as anteriores da mesma conversa, porque o agente descarta o evento mais antigo que o contexto. A task imprime `ok` ou `falhou` por expectativa, com a contagem e até 10 itens, e termina com código 1 quando alguma falha.

## O que o sistema garante

- Com réplicas de `web`, `jobs-webhooks`, `broker-web`, `broker-consumer` e `agent-mock`, nenhuma resposta, entrega ou ação aceita é duplicada, e toda mensagem enviada ao agente tem ação ou escalação.
- O webhook de um worker morto volta à fila em até cerca de 75 s, sem intervenção.
- Uma requisição de WhatsApp ou da entrada JSON do chat acima do limite da marca não grava nada e recebe `429` com `Retry-After: 1`.
- Um envio do widget acima do limite do lojista ou do teto do widget na marca não grava nada no domínio e recebe `429` com `Retry-After`; o widget não lê nem incrementa o contador do limite da marca.
- Uma ação da DLQ volta a `agent.outbound` com a mesma chave, o mesmo valor e na mesma partição das ações do agente para a conversa, e a republicação fica registrada em `dlq.reprocessed`; uma ação já aplicada não produz segundo efeito.
- A mensagem da DLQ de outra marca não aparece na tela, e a ilegível ou sem conversa da marca não é republicada.
- O Kafka continua só no Broker, e o Broker continua sem acesso ao banco.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Integração com o atendente por webhooks e broker | Réplicas do Broker e do agente; reprocessamento da DLQ pela operação | Webhook (F7), Broker (F9), agente mock (F10) |
| Rastreabilidade e auditoria | `dlq.reprocessed` com origem, destino e operador | Linha do tempo (F14) |
| Múltiplas filas configuráveis pela operação | Tela da DLQ no admin, na marca da sessão | Admin de filas e regras (F13) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min sem backlog crescente | Escala por réplica dos papéis que carregam a meta; dimensionamento de threads, pool e `max_connections`; perfil de carga sem recarregamento nem logs verbosos |
| H2 · entrada → Kafka com p95 < 300 ms | Mais réplicas do `web`, do `jobs-webhooks` e do `broker-web`; o `web-lb` fica fora do trecho medido |
| H3 · nenhuma perda nem duplicação | Recuperação do worker morto em cerca de 30 a 75 s; `robustness:check` para a conferência no Core; DLQ reprocessável |
| H4 · ponta a ponta com p95 < 1 s | Réplicas do `broker-consumer` e do `agent-mock` pelas partições |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 2 · Cockpit operacional | O `broker-web` em réplicas aparece no Prometheus com uma instância por réplica |
| 4 · Modos de falha do agente mock | A `robustness:check` confere a ausência de duplicação depois dos modos `duplicate` e `stale` |

## Limitações

- **Salto do balanceador fora da medida.** O nginx não registra acesso, e o `received_at` é carimbado pelo `web` depois dele; o tempo do `web-lb` não aparece na H2 nem na H4.
- **Um balanceador.** O `web-lb` tem uma réplica; a queda dele interrompe a entrada HTTP até o Compose subi-lo de novo.
- **Contadores no mesmo Postgres.** O limite de taxa grava no Solid Cache, no mesmo banco do domínio, um incremento por marca em cada requisição de WhatsApp ou da entrada JSON do chat e até dois em cada envio do widget.
- **Contador aproximado no início da janela.** O `lock_and_write` do Solid Cache trava a linha do contador só quando ela existe. Incrementos simultâneos que criam a linha podem contar como um, e o limite da marca e os do widget deixam passar esse excedente. Com 3 threads incrementando uma chave nova ao mesmo tempo, 4 de 5 rodadas contam 1 em vez de 3.
- **Teto do widget compartilhado.** Um script com vários lojistas ocupa os 10 por segundo da marca e recusa o formulário de outros lojistas enquanto durar. O WhatsApp e a entrada JSON do chat seguem aceitando.
- **Login simulado.** Quem escolhe um lojista na tela do widget consome o limite dele.
- **Janela fixa.** Os limites contam por janela de relógio: uma rajada na virada passa cerca do dobro do limite em menos de 1 s. No widget, são cerca de 10 mensagens do lojista e 20 por marca.
- **Soma dos limites.** Cada marca aceita cerca de 500 mensagens por segundo do WhatsApp e da entrada JSON do chat, mais 10 do widget.
- **Leituras do widget sem limite.** As páginas do widget (`GET`) e a escolha do lojista não passam pelo limite de taxa.
- **`429` do widget sem JavaScript.** A página fica na URL do envio: recarregá-la repete o envio, e abrir essa URL direto responde 404.
- **Listagem da DLQ limitada.** A tela lê as últimas 50 mensagens de cada partição de `agent.dlq` e filtra pela marca; com mensagens de outra marca entre as últimas, a listagem traz menos que 50, e as mais antigas não aparecem nem podem ser reprocessadas pela tela.
- **Republicação sem evento.** Se a gravação do `dlq.reprocessed` falhar depois do `200` do Broker, a ação já está em `agent.outbound` sem o evento; o erro vai ao log com origem e destino.
- **Uma mensagem por vez.** Não existe reprocessamento em lote nem bloqueio de repetição; a repetição é segura pela deduplicação do Core.
- **Índice de `with_ai` no ambiente local.** Com poucas conversas e metade delas em `with_ai`, o planejador não usa o `index_conversations_with_ai`; o ganho aparece com o volume de conversas encerradas.
- **Sem pooler.** A conta de conexões é a soma dos processos; escalar além do `max_connections` exige aumentar o valor ou um pooler (seção "Evolução" da arquitetura).
- **`metrics` e `jobs-default` sem escala.** O `metrics` guarda o cursor em memória, e o `jobs-default` roda as tarefas recorrentes; os dois ficam com uma réplica.

## Operação

### Processos

| Serviço | Comando | Porta no host | Réplicas |
| - | - | - | - |
| `web-lb` | nginx com `infra/nginx/nginx.conf` | `3000` | 1 |
| `web` | `bin/rails server -b 0.0.0.0 -p 3000 -P /tmp/server.pid` | nenhuma | `--scale web=N` |
| `jobs-webhooks` | `bin/jobs --config-file config/queue_webhooks.yml --skip-recurring` | nenhuma | `--scale jobs-webhooks=N` |
| `broker-web` | `bundle exec puma -C config/puma_broker.rb broker.ru` | nenhuma | `--scale broker-web=N` |
| `broker-consumer` | `bundle exec karafka server` | nenhuma | `--scale broker-consumer=N`, até 6 com partição |
| `agent-mock` | `agent-mock run` | nenhuma | `--scale agent-mock=N`, até 6 com partição |

Exemplo da configuração da verificação:

```text
CLOUDESK_LOAD_PROFILE=1 docker compose up -d --scale web=2 --scale jobs-webhooks=2 --scale broker-web=2 --scale broker-consumer=2 --scale agent-mock=2
```

### Configuração

| Variável | Uso | Valor no Compose |
| - | - | - |
| `CLOUDESK_LOAD_PROFILE` | `1` liga o perfil de carga dos processos Rails | vazio |
| `WEB_MAX_THREADS` | Threads do Puma e conexões do pool de cada réplica do `web` | `3` |
| `POSTGRES_MAX_CONNECTIONS` | `max_connections` do Postgres | `200` |
| `BROKER_DLQ_URL` | Base dos endpoints da DLQ no `broker-web` | `http://broker-web:3000` |
| `BROKER_DLQ_SECRET` | Assinatura das chamadas do Core aos endpoints da DLQ, a mesma nos dois | `.env` |
| `CORE_ACTIONS_URL` | API de ações do Core, pelo balanceador | `http://web-lb:3000/api/v1/agent/actions` |

### Medida

O roteiro `experiment/scale/measure_idle.sh` (com o `README.md` da mesma pasta) sobe o ambiente com `CLOUDESK_LOAD_PROFILE=1`, mede o TPS e as conexões ociosas com 1, 2 e 4 réplicas de cada worker, conta as conexões por contêiner e roda uma carga leve com os papéis escaláveis em 2 réplicas. Os números estão em "Dimensionamento".

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/channels/rate_limit_spec.rb` | Dentro, no limite e acima dele; janela nova no segundo seguinte; contagem por mensagem; marcas independentes; incremento das marcas já contadas; log da recusa; contador indisponível deixa passar com log. No widget: 5 por lojista em 10 s e 10 por segundo na marca, com escopo e `retry_after`; janela seguinte; lojistas e marcas independentes; recusa por lojista fora do contador do widget da marca; contador da marca intocado e sem efeito no widget; contador indisponível; log com marca e id do lojista |
| `core/spec/requests/channels/whatsapp_webhooks_spec.rb` e `chat_messages_spec.rb` | `429` com `Retry-After: 1` e `rate_limited`, sem mensagem, `audit_event` nem job; payload com duas marcas em que uma passa do limite não grava nada; janela seguinte aceita |
| `core/spec/requests/channels/chat_widget_spec.rb` | `303` dentro do limite; `429` com `Retry-After`, aviso e texto no campo, sem mensagem, `audit_event` nem job; aviso e texto fora da página seguinte; sessão nova do mesmo lojista recusada; entrada JSON da mesma marca com `200` depois da recusa; mensagem vazia não conta; janela seguinte aceita; texto com HTML escapado |
| `core/spec/models/brand_spec.rb` | Padrão 500, validação e `CHECK` maior que 0 |
| `core/spec/db/partial_indexes_spec.rb` | Os três índices em `pg_indexes`, com colunas e predicado |
| `core/spec/broker/dlq_reader_spec.rb` | Leitura das últimas mensagens por partição, mensagem sem `brand`, valor não JSON e busca por posição |
| `core/spec/broker/dlq_endpoints_spec.rb` | Assinatura, timestamp e caminho com query string; listagem filtrada, ordenada e limitada; republicação com a mesma chave e o mesmo valor, sem headers `dlq_*`; `404`, `422 brand_mismatch`, `422 invalid_payload` e `503` |
| `core/spec/broker/webhook_app_spec.rb` | Rotas `/dlq/messages` encaminhadas, sem contar como webhook; rotas atuais sem mudança |
| `core/spec/broker/producer_spec.rb` | Produtor com `partitioner` `murmur2_random`, `acks=all`, idempotência e `message.timeout.ms` de 3000 |
| `core/spec/broker/isolation_spec.rb` | O Broker carrega sem Rails e sem banco com os arquivos novos |
| `core/spec/modules/admin/dlq_client_spec.rb` | Assinatura conferida com `Contract::Signature`, corpo, timeouts, `200`, erro de rede, tempo esgotado e status de erro |
| `core/spec/modules/admin/dlq_reprocessor_spec.rb` | `dlq.reprocessed` com o payload completo; segundo reprocessamento grava segundo evento; erro do Broker não grava; `invalid_message`, chave fora da marca, chave que não é UUID, outra marca, sem marca e mensagem fora da listagem recusados sem chamar o Broker; log de origem e destino quando a gravação falha |
| `core/spec/requests/admin/dlq_spec.rb` | Basic auth; sem marca volta à escolha; listagem com reprocessamentos anteriores e botão desabilitado com motivo; erro do Broker na página; `POST` redireciona com o offset novo ou com o erro |
| `core/spec/tasks/robustness_check_spec.rb` | Cenário limpo `ok`; `agent.reply` duplicado, `message.delivered` duplicado e mensagem sem ação `falhou`; escalação `ai_timeout` e ação sobre mensagem mais nova cobrem a mensagem; `SINCE` filtra |
| `core/spec/modules/agents/recover_interrupted_webhooks_job_spec.rb` | Tarefa a cada 15 s |
| `core/spec/lib/solid_queue_config_spec.rb` | Heartbeat de 5 s, limiar de 30 s e um processo por worker |

Suítes: RSpec do Core com 1055 exemplos e 0 falhas; pytest do `agent_mock` (417) e do `channel_simulator` (106); kit de conformidade com 16 testes e código 0.

No Compose:

- `docker compose ps`: `web-lb` com `0.0.0.0:3000`; `web` e `broker-web` sem porta no host. `/up`, `/panel`, `/admin` e `/chat/infinitepay` respondem pelo balanceador; o redirect do admin mantém `localhost:3000`; o simulador assina os streams pelo Action Cable em `ws://web-lb:3000/cable`, e as respostas da IA no chat chegam pelo WebSocket, sem "Request origin not allowed" no log.
- `Brand.pluck(:slug, :inbound_rate_limit_per_second)`: as duas marcas com 500.
- Limite: com a infinitepay em 2 por segundo, `send --channel chat --brand infinitepay --count 20 --rate 20` teve 11 respostas `200` e 9 `429`; nenhuma das 9 mensagens existe no Core, e o log do `web` mostra "limite de taxa: marca infinitepay, canal chat, 3 mensagens no segundo, limite 2". Limite restaurado para 500.
- Limite do widget, no Solid Cache: 5 chamadas de `check_widget` para cada um de 3 lojistas no mesmo segundo dão 10 aceitas e 5 recusadas, e o contador da marca fica nulo.
- Limite do widget, no formulário: 7 envios do mesmo lojista por `curl` na mesma janela dão cinco `303` e dois `429`, com `Retry-After` de 2 e 1, e o log do `web` mostra "6 mensagens em 10 s, limite 5"; logo depois, `send --channel chat --brand infinitepay --count 5 --rate 5` tem 5 respostas `200`.
- Limite do widget, no Chrome headless: a 6ª mensagem em menos de 10 s mostra o aviso no topo e o texto no campo, com a URL em `/chat/infinitepay/conversation`; o reenvio na janela seguinte recebe `303`, e a mensagem entra no histórico.
- Escala: com `web`, `jobs-webhooks`, `broker-web`, `broker-consumer` e `agent-mock` em 2 réplicas, o Prometheus mostra duas instâncias em `up{job="broker-web"}`. `send --channel all --count 1200 --rate 40` (1200 mensagens do lojista, 645 enviadas ao agente, 78 `agent.reply`, 78 `agent.action.stale`, 24 `agent.escalate`, 78 `message.delivered`); o lag de `cloudesk-agent` e `cloudesk-broker` zera em menos de 30 s e a `robustness:check` dá `ok` nas quatro linhas, com código 0.
- Worker morto: durante `send --count 2400 --rate 40`, com 5 webhooks em execução, `docker kill` em uma réplica do `jobs-webhooks`; processo removido em 28 s, os 5 jobs na fila de falhas e a fila vazia em 62 s; `robustness:check` `ok`.
- DLQ: uma ação `categorize` com `based_on_sequence` maior que `last_sequence` recebe `422` e vai a `agent.dlq` com `core_rejected`; na tela, "Reprocessar" mostra "Mensagem 0@3 republicada em agent.outbound/3@135", o `broker-web` registra a republicação, o `broker-consumer` recebe `422` de novo e a ação volta à DLQ no offset 4; `audit_events` tem `dlq.reprocessed` com origem, destino e `operator_name`. Uma mensagem ilegível (`invalid_message`) aparece com o botão desabilitado e o motivo; a mensagem de outra marca não aparece.
- DLQ, ação já aceita: com o `agent-mock` e o `web-lb` parados, uma resposta válida publicada em `agent.outbound` vai à DLQ com `retries_exhausted` depois de 10 tentativas; com o `web-lb` de volta, dois reprocessamentos dão um único `agent.reply`, uma mensagem `ai`, um `message.delivered`, uma linha em `processed_events` e dois `dlq.reprocessed`, sem nova entrada na DLQ. A mesma ação, com a conversa já escalada por `ai_timeout`, recebe `409 rejected` (`agent.action.rejected`) e também não volta à DLQ.
- Partição: num tópico temporário de 6 partições, 12 chaves UUID publicadas pelo `Broker::Producer`, pelo `rpk topic produce -k` e calculadas pelo `DefaultPartitioner` do `aiokafka` 0.15.0 caem na mesma partição nas três fontes; com o particionador padrão do librdkafka (`consistent_random`), 11 das 12 caem em outra. O tópico é apagado ao fim. Na DLQ, as ações do agente lidas em `agent.outbound` 0@75 e 3@136 (header `dlq_source_partition`) são republicadas em 0@78 e 3@140, nas mesmas partições, e nenhuma volta à DLQ.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco e multi-marca (F1) | Coluna em `brands`, fora do RLS; índices parciais com `brand_id` |
| Canais (F4) | Limite de taxa nos controllers de WhatsApp, da entrada JSON do chat e do widget, antes do `Conversations::Intake` |
| Simulador (F5) | Chama o Core pelo `web-lb`; registra as respostas `429` no `sent.jsonl` |
| Saída para o Broker (F7) | `jobs-webhooks` em réplicas; heartbeat e `recover_interrupted_webhooks` a cada 15 s |
| API de ações (F8) | Deduplica as ações republicadas da DLQ pela `Idempotency-Key` |
| Broker (F9) | Endpoints da DLQ no `broker-web`; réplicas do `broker-web` e do `broker-consumer`; produtor com o particionador `murmur2_random` |
| Agente mock (F10) | Réplicas no grupo `cloudesk-agent`; lê o contexto pelo `web-lb` |
| Handoff e timeout (F11) | Índices da varredura e da capacidade do analista |
| Admin (F13) | Tela `/admin/dlq` no layout e na autenticação do admin |
| Observabilidade (F14) | Métricas usadas pela medida; réplicas do `broker-web` pela descoberta por DNS |
| Experimento técnico (F18) | Escala, dimensionamento, perfil de carga e `robustness:check` |

## Fontes

- `documents/arquitetura.md`, seções "Processos", "Decisões de design", "Robustez" e "Limites conhecidos"
- `documents/fases/08-saida-core-broker.md`, seções "Limitações" e "Relação com as outras partes"
- `documents/fases/10-broker.md`, seção "DLQ"
- Código da gem `solid_queue` 1.7.2 (`lib/solid_queue.rb`, `lib/solid_queue/supervisor/maintenance.rb`) e README
- Código da gem `karafka` 2.6.1 (`lib/karafka/admin.rb`, `lib/karafka/admin/topics.rb`)
- Código da gem `karafka-rdkafka` 0.32.2 (`lib/rdkafka/producer.rb`, particionador padrão `consistent_random`) e do `aiokafka` 0.15.0 (`DefaultPartitioner`, murmur2)
- Código da gem `actioncable` (`lib/action_cable/connection/base.rb`, conferência do `Origin`)
- Código da gem `solid_cache` 1.0.10 (`lib/solid_cache/store/api.rb`, `increment`)
- Configuração do `web-lb` validada com `nginx -t` na imagem `nginx:1.30.8-alpine`, inclusive o parâmetro `resolve` do `server` no `upstream`

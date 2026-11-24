# Cloudesk · Broker

## O que é

O Broker é a ponte entre o Core e o Kafka, nos dois sentidos. Ele roda em dois processos, da mesma imagem e do mesmo código do Core:

- **`broker-web`** recebe o webhook `message.created` do Core e publica o evento em `agent.inbound`, onde o agente o consome;
- **`broker-consumer`** consome as ações do agente em `agent.outbound` e as entrega à API de ações do Core.

O Broker não acessa o banco e não guarda estado. Ele fala com o Core somente por HTTP assinado e com o agente somente pelo Kafka. O código fica em `core/lib/broker/` e roda sem Rails: carrega só o contrato (`core/lib/contract/`), o contexto de trace (`core/lib/trace_context.rb`), o Karafka, o WaterDrop e o cliente do Prometheus (gem `prometheus-client`).

## Onde fica no fluxo

```text
Core (jobs-webhooks) → POST /webhooks/message-created → broker-web → agent.inbound → agente
                                                                                       │
Core ← POST /api/v1/agent/actions ← broker-consumer ← agent.outbound ◄─────────────────┘
                                          │
                                          └→ agent.dlq (ação que não pode ser processada)
```

Na ida, o Broker é o ponto em que a mensagem sai do Postgres e entra no Kafka. Na volta, é o ponto em que a decisão do agente sai do Kafka e chega ao Core. Os dois sentidos são processos separados: cada um escala pela sua carga, e a queda de um não interrompe o outro.

## Por que existe e que valor gera

**Nenhuma perda na ida.** O `broker-web` só responde `200` depois que o Kafka confirma a gravação da mensagem. Sem confirmação, responde erro, e o job do Core reenvia com backoff. Uma queda do Broker ou do Kafka em qualquer instante resulta em reenvio, nunca em perda. Essa é a base da hipótese H3.

**Nenhuma perda na volta.** O `broker-consumer` marca uma ação como consumida só depois do resultado final dela: aceita, recusada pelo Core ou publicada na DLQ. Se o processo cai no meio, a ação volta a ser entregue ao reiniciar; a repetição chega ao Core com a mesma `Idempotency-Key` e não produz segundo efeito.

**Isolamento por fronteira HTTP.** O Broker compartilha com o Core a implementação do contrato e da assinatura, mas não tem acesso ao banco nem às regras internas, como na estrutura de referência: help desk → webhooks → broker → Kafka → agente.

**Ordem por conversa no Kafka.** A chave de cada mensagem é o `conversation_id`, e o Kafka entrega as mensagens de uma partição na ordem em que foram gravadas. Os eventos de uma conversa chegam ao agente na ordem em que o Broker os publicou.

**Rastreabilidade.** O Broker carimba o horário de recebimento do webhook e continua o trace W3C em cada salto. Com o timestamp do registro Kafka, esses carimbos permitem separar, na linha do tempo, o tempo do Core, do Broker e do Kafka.

## Como funciona

### Ida: webhook para o Kafka

`Broker::WebhookApp` é um app Rack servido pelo Puma do `broker-web` (`core/broker.ru`, `core/config/puma_broker.rb`). Para cada `POST /webhooks/message-created`:

1. **Carimbo.** Grava o horário de chegada (`broker_received_at`), antes de qualquer conferência.
2. **Assinatura.** Confere o HMAC-SHA256 com `BROKER_WEBHOOK_SECRET` (`Contract::Signature.verify!`), sobre o corpo bruto e o caminho com a query string. A conferência vem antes da leitura do corpo como JSON.
3. **Contrato.** Lê o JSON e confere o schema `webhook.message-created`.
4. **Publicação.** Publica em `agent.inbound` com `produce_sync` e espera a confirmação do Kafka.
5. **Resposta.** `200` com a posição da mensagem no Kafka.

A mensagem em `agent.inbound`:

| Parte | Conteúdo |
| - | - |
| Valor | O corpo recebido, byte a byte, sem nova serialização |
| Chave | `conversation_id` |
| Header `brand` | Slug da marca do evento |
| Header `traceparent` | Mesmo `trace_id` do header HTTP recebido, com `parent_id` do Broker (`TraceContext.continue`) |
| Header `broker_received_at` | Horário de chegada do webhook, em UTC com milissegundos |
| Timestamp do registro | Horário de gravação no Kafka (`LogAppendTime` do tópico) |

Os headers são conferidos pelo schema `kafka.inbound-headers` antes da publicação.

| Código | Corpo | Situação |
| - | - | - |
| `200` | `topic`, `partition`, `offset` | Mensagem confirmada pelo Kafka |
| `401` | `invalid_signature`, `expired_timestamp` | Assinatura ausente, errada ou fora da janela de 300 s |
| `422` | `invalid_payload` | JSON inválido ou fora do schema `webhook.message-created` |
| `503` | `kafka_unavailable` | O Kafka não confirmou a publicação |
| `404`, `405` | `not_found`, `method_not_allowed` | Fora da rota ou do método |

Os erros seguem o formato das respostas da API do Core: `status`, `error` e `message`. `GET /up` responde `200` e serve de healthcheck do contêiner. `GET /metrics` serve, no formato de texto do Prometheus, a latência entrada → Kafka e a contagem das respostas do webhook por código (`Broker::Metrics`); o detalhamento está em `documents/fases/15-observabilidade.md`.

Para o Core, o `503` é transitório e o job reenvia com backoff; o `401` e o `422` são permanentes e levam o job à fila de falhas (`Agents::BrokerClient`).

### Produtor Kafka

Cada processo tem um único produtor WaterDrop (`Broker::Producer`), compartilhado pelas 5 threads do Puma do `broker-web` e pelos workers do `broker-consumer`.

| Configuração | Valor | Motivo |
| - | - | - |
| `acks` | `all` | A confirmação só chega com a mensagem gravada |
| `enable.idempotence` | `true` | O reenvio interno do produtor não grava a mensagem duas vezes |
| `message.timeout.ms` | `3000` | O padrão do WaterDrop é 150 s; com 3 s, o `broker-web` responde `503` antes dos 5 s de leitura do Core (`Agents::BrokerClient`) |
| `partitioner` | `murmur2_random` | A partição é o murmur2 da chave, a mesma fórmula do `aiokafka` do agente e do `rpk`; o padrão do librdkafka (`consistent_random`, CRC32) escolhe outra partição para a mesma chave. Com o murmur2, a ação republicada da DLQ cai na partição de `agent.outbound` das ações do agente para a conversa |

O produtor do `broker-web` é fechado quando o Puma para; o do `broker-consumer`, quando o Karafka para.

### Volta: Kafka para a API de ações

`Broker::ActionsConsumer` roda no `karafka server` do `broker-consumer` (`core/karafka.rb`), no grupo de consumidores `cloudesk-broker`, a partir do início do tópico quando o grupo ainda não tem posição gravada. Os offsets são marcados pelo próprio consumidor (`manual_offset_management`), mensagem a mensagem, só depois do resultado final.

Para cada ação:

1. **Chave.** Lê o valor como JSON e deriva a `Idempotency-Key` (`<inbound_event_id>:<type>`, `Contract::IdempotencyKey.for_action`). O schema da ação é conferido pelo Core.
2. **Chamada.** `POST` em `CORE_ACTIONS_URL` com o valor Kafka sem alteração, assinado com `AGENT_ACTIONS_SECRET` sobre os mesmos bytes, com a `Idempotency-Key` e o `traceparent` do salto (mesmo `trace_id` do header Kafka, `parent_id` do Broker). Conexão nova por chamada, 2 s para conectar e 5 s para ler.
3. **Decisão**, pela resposta do Core:

| Resposta | Classificação | O que o consumidor faz |
| - | - | - |
| `200` | Final | Marca e segue |
| `409` (`stale`, `rejected`) | Final | Marca e segue, sem retry e sem DLQ |
| `408`, `429`, `5xx`, erro de rede | Transitória | Lança; o Karafka reprocessa a ação depois de uma pausa |
| Demais status (`400`, `401`, `404`, `422`) | Permanente | Publica na DLQ, marca e segue |
| Valor que não é JSON, ou sem `inbound_event_id` e tipo de ação conhecido | Permanente | Publica na DLQ sem chamar o Core, marca e segue |

O `409` é decisão de negócio do Core: a ação ficou desatualizada ou a conversa saiu da IA. Reenviar não mudaria o resultado.

### Retry das falhas transitórias

O retry é o da pausa nativa do Karafka. O consumidor lança a exceção, a partição pausa e, ao fim da pausa, o Karafka volta a entregar a partir da ação que falhou; as ações anteriores do mesmo lote já estão marcadas e não se repetem.

| Configuração | Valor |
| - | - |
| `pause.timeout` | 2 s |
| `pause.max_timeout` | 60 s |
| `pause.with_exponential_backoff` | `true` |

A pausa depois da tentativa `n` é `pause.timeout × 2^n`, limitada a `pause.max_timeout`: 4, 8, 16, 32 e 60 s nas seguintes. Na 10ª tentativa com falha transitória, o consumidor publica a ação na DLQ e marca. Do primeiro erro à DLQ são cerca de 6 minutos de pausas, mais o tempo de cada chamada. A pausa vale para a partição inteira: as outras ações da partição esperam, o que mantém a ordem das ações de cada conversa.

### DLQ

O `broker-consumer` publica em `agent.dlq` com o próprio produtor (`Broker::DeadLetter`), com `produce_sync`. O recurso de DLQ da versão open source do Karafka preserva só o payload; a publicação própria preserva a mensagem inteira:

| Parte | Conteúdo |
| - | - |
| Chave | A chave original |
| Valor | O valor original, byte a byte |
| Headers | Os headers originais, mais os de diagnóstico do schema `kafka.dlq-headers` |

| Header de diagnóstico | Conteúdo |
| - | - |
| `dlq_reason` | `core_rejected` (recusa permanente do Core), `invalid_message` (valor sem `Idempotency-Key` derivável, sem chamada ao Core) ou `retries_exhausted` (falha transitória na 10ª tentativa) |
| `dlq_status` | Status HTTP da última resposta do Core; ausente quando o Core não foi chamado ou não respondeu |
| `dlq_source_topic`, `dlq_source_partition`, `dlq_source_offset` | Posição da ação em `agent.outbound` |
| `dlq_failed_at` | Horário da publicação na DLQ, em UTC com milissegundos |

Se a publicação na DLQ não é confirmada, o consumidor lança e a ação entra no mesmo retry: a ação só é marcada depois de gravada na DLQ. As ações da DLQ são reprocessadas pela tela `/admin/dlq` do Core, pelos endpoints da DLQ no `broker-web` (`documents/fases/16-robustez-e-escala.md`).

### Sem Rails no processo

Os dois processos usam a imagem do Core, mas não carregam o Rails. O `core/lib/broker.rb` é o carregador único, e a pasta `core/lib/broker/` fica fora do autoload do Core (`config.autoload_lib`).

O Karafka carrega o Rails sozinho quando o encontra: no `require "karafka"`, faz `require "rails"`, e o CLI carrega `config/environment.rb` quando o arquivo existe na pasta. A variável `KARAFKA_REQUIRE_RAILS=false` desliga as duas coisas. Ela fica no ambiente dos dois serviços no Compose, porque o CLI carrega o Karafka antes do `karafka.rb`, e também no `core/lib/broker.rb`, para o Puma e os testes. O Compose não passa as variáveis `DB_*` aos dois serviços.

## O que o sistema garante

- O Core recebe `200` do `broker-web` só com a mensagem gravada em `agent.inbound`.
- A mensagem em `agent.inbound` tem o corpo exato que o Core assinou, a chave da conversa e os headers do contrato.
- Webhook sem assinatura válida, fora da janela de tempo ou fora do contrato não chega ao Kafka.
- Uma ação em `agent.outbound` só é marcada como consumida depois do resultado final: aceita, recusada com `409` ou gravada na DLQ.
- Uma ação reentregue pelo Kafka chega ao Core com a mesma `Idempotency-Key`.
- Uma ação na DLQ mantém chave, valor e headers originais e diz por que foi para lá.
- Nenhum dos dois processos tem acesso ao banco nem carrega o Rails.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Integração com o atendente por webhooks e broker | O Broker nos dois sentidos: webhook para o Kafka e Kafka para a API de ações, com assinatura, confirmação, retry e DLQ | Webhook de ida (F7), API de ações (F8), agente mock (F10) |
| Rastreabilidade e auditoria | `broker_received_at` e `traceparent` nos headers de `agent.inbound`, e o `traceparent` continuado na chamada à API de ações | Gravação dos carimbos no `audit_event` da ação (F8), linha do tempo (F14) |
| Multi-marca | A marca no header `brand` de `agent.inbound` | RLS e marca no corpo da ação (F1, F8) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H2 · latência entrada → Kafka com p95 < 300 ms | O fim do trecho medido é a confirmação do Kafka no `broker-web`; `broker_received_at` e o timestamp do registro separam o tempo do Broker do tempo do Kafka |
| H3 · nenhuma perda nem duplicação com o broker reiniciado | `200` só depois da confirmação na ida; marcação só depois do resultado final na volta; a repetição de qualquer lado chega ao Core com a mesma chave |
| H1 · sem backlog crescente | O lag do grupo `cloudesk-broker` em `agent.outbound` é uma das medidas de backlog |
| H4 · latência ponta a ponta | O Broker está nos dois sentidos do caminho medido |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 4 · Modos de falha do agente mock | A ação duplicada e a desatualizada passam pelo Broker como qualquer ação; o `200` repetido e o `409 stale` são resultado final e não vão à DLQ |
| 2 · Cockpit operacional | O lag do grupo `cloudesk-broker` e o volume de `agent.dlq` são dados do painel da F14 |

## Limitações

- **Sem jitter no retry da volta.** A pausa do Karafka cresce de forma exponencial, sem variação aleatória. Ações que falham juntas voltam juntas.
- **Pausa por partição.** Uma ação com falha transitória segura as ações seguintes da mesma partição, inclusive as de outras conversas que caem nela, até o fim do retry ou a DLQ.
- **Leitura de 5 s.** Uma chamada ao Core que demora mais de 5 s é tratada como falha transitória, mesmo que o Core termine de processá-la. A repetição é inofensiva, porque a chave é a mesma, mas conta uma tentativa.
- **Um produtor por processo.** O `broker-web` não tem fila própria: com o Kafka fora do ar, cada webhook espera até 3 s e recebe `503`, e o volume fica retido no Solid Queue do Core.
- **DLQ reprocessada uma mensagem por vez.** As ações em `agent.dlq` ficam gravadas com o diagnóstico e voltam a `agent.outbound` uma por vez, pela tela `/admin/dlq`.
- **Um nó Redpanda.** O `acks=all` confirma a gravação no único nó do ambiente local, sem réplica.

## Operação

### Processos

| Serviço | Comando | Porta no host |
| - | - | - |
| `broker-web` | `bundle exec puma -C config/puma_broker.rb broker.ru` | nenhuma: alcançado pelo DNS do Compose, na porta 3000 |
| `broker-consumer` | `bundle exec karafka server` | nenhuma |

Os dois sobem depois do `redpanda-init`, que cria os tópicos.

### Configuração

| Variável | Uso | Valor no Compose |
| - | - | - |
| `KAFKA_BROKERS` | Endereço do Kafka | `redpanda:9092` |
| `CORE_ACTIONS_URL` | API de ações do Core, pelo balanceador | `http://web-lb:3000/api/v1/agent/actions` |
| `BROKER_WEBHOOK_SECRET` | Assinatura do webhook, a mesma do Core | `.env` |
| `AGENT_ACTIONS_SECRET` | Assinatura das chamadas à API de ações, a mesma do Core | `.env` |
| `BROKER_DLQ_SECRET` | Assinatura das chamadas do Core aos endpoints da DLQ no `broker-web`, a mesma do Core | `.env` |
| `CONTRACTS_PATH` | Pasta do contrato | `/contracts` |
| `KARAFKA_REQUIRE_RAILS` | Impede o Karafka de carregar o Rails | `false` |

`KAFKA_BROKERS` e `CORE_ACTIONS_URL` têm padrão no `compose.yaml` e podem ser trocados no `.env`.

### Inspeção no Redpanda

```text
docker compose exec redpanda rpk topic consume agent.inbound -o :end -f '%p %o %k %h{%k=%v; }\n'
docker compose exec redpanda rpk topic consume agent.dlq -o :end -f '%k %h{%k=%v; }\n%v\n'
docker compose exec redpanda rpk group describe cloudesk-broker
```

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/broker/webhook_app_spec.rb` | `200` com corpo inalterado, chave, headers e posição; `traceparent` com o mesmo `trace_id` e `parent_id` novo; `broker_received_at` com milissegundos; `401` por assinatura, corpo alterado, outro segredo e timestamp vencido; `422` por JSON e schema; `503` sem confirmação do Kafka; `404`, `405` e `/up` |
| `core/spec/broker/core_client_spec.rb` | Assinatura conferida com `Contract::Signature.verify!`, `Idempotency-Key`, corpo idêntico e `traceparent`; classificação de `200`, `409`, `4xx`, `408`, `429`, `5xx` e erros de rede |
| `core/spec/broker/actions_consumer_spec.rb` | `200` e `409` marcam sem DLQ; recusa permanente e valor ilegível vão à DLQ com chave, valor e headers originais mais os de diagnóstico; falha transitória lança antes da 10ª tentativa e vai à DLQ na 10ª; falha na DLQ lança sem marcar; o lote para na ação que falhou |
| `core/spec/broker/isolation_spec.rb` | `core/lib/broker.rb` e o CLI do Karafka, em processos novos, não definem `Rails` nem `ActiveRecord` |
| `core/spec/contract/` e `agent_mock/tests/contract/` | Schema `kafka.dlq-headers` e seus exemplos em Ruby e em Python |

Os testes do Broker usam `core/spec/broker_helper.rb`, sem `rails_helper`: o Kafka é substituído pelo cliente em memória do WaterDrop e pelo `karafka-testing`, e o Core pelo WebMock.

No Compose:

- webhook com assinatura inválida e com timestamp vencido no `broker-web` recebem `401`;
- uma mensagem do simulador aparece em `agent.inbound` com a chave da conversa e os três headers, e o mesmo webhook publicado de novo cai na mesma partição;
- com o Redpanda parado, o `broker-web` responde `503` em cerca de 3 s e o job do Core entra em retry; com o Redpanda de volta, o webhook é entregue;
- uma ação válida publicada em `agent.outbound` grava `agent.reply` no Core, e a resposta chega ao simulador; a mesma ação de novo não produz efeito nem vai à DLQ;
- uma ação com `based_on_sequence` antigo grava `agent.action.stale` e não vai à DLQ;
- uma ação fora do schema recebe `422` e vai a `agent.dlq` com chave, valor e headers originais mais os de diagnóstico;
- com o `web` parado, o log do `broker-consumer` mostra as tentativas com pausas de 4, 8, 16, 32 e 60 s; com o `web` de volta, a ação é entregue e o offset é marcado;
- os contêineres do Broker não têm variáveis `DB_*`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Contrato (F3) | Schemas `webhook.message-created`, `kafka.inbound-headers` e `kafka.dlq-headers`, assinatura e `Idempotency-Key`; o Broker usa a mesma implementação em Ruby do Core |
| Saída para o Broker (F7) | O Core envia o webhook e reenvia com backoff no `503`; o `401` e o `422` vão à fila de falhas |
| API de ações (F8) | Recebe a ação do Broker e responde com os códigos que o consumidor classifica |
| Agente mock (F10) | Consome `agent.inbound` e publica em `agent.outbound` com a chave da conversa e os headers `brand` e `traceparent` |
| Observabilidade (F14) | Lag do grupo, volume da DLQ e carimbos do Broker na linha do tempo |
| Robustez e escala (F15) | Réplicas do `broker-web` e do `broker-consumer`; endpoints da DLQ no `broker-web` e reprocessamento pela tela `/admin/dlq` |

## Fontes

- `documents/arquitetura.md`, seções "Contrato com o agente", "Idempotência", "Ação sobre contexto desatualizado" e "Decisões de design"
- `documents/fases/04-contrato-de-integracao.md`, seções "Headers das mensagens Kafka", "Horário de gravação no Kafka", "Assinatura" e "`Idempotency-Key`"
- `documents/fases/08-saida-core-broker.md`, seções "A requisição", "Como a resposta é tratada" e "Novas tentativas"
- `documents/fases/09-api-de-acoes-e-contexto.md`, seção "Respostas ao Broker"
- [rubygems · karafka](https://rubygems.org/gems/karafka)
- [rubygems · karafka-testing](https://rubygems.org/gems/karafka-testing)
- [Karafka · Error Handling and Back Off Policy](https://karafka.io/docs/Consumer-Groups-Error-Handling-and-Back-Off-Policy/)
- [Karafka · Dead Letter Queue](https://karafka.io/docs/Consumer-Groups-Dead-Letter-Queue/)
- [Karafka · Pausing, Seeking and Rate Limiting](https://karafka.io/docs/Consumer-Groups-Pausing-Seeking-and-Rate-Limiting/)
- [Karafka · Offset management](https://karafka.io/docs/Consumer-Groups-Offset-management/)
- [Karafka · Testing](https://karafka.io/docs/Basics-Testing/)
- [WaterDrop · Usage](https://karafka.io/docs/WaterDrop-Usage/)
- [WaterDrop · Testing](https://karafka.io/docs/WaterDrop-Testing/)

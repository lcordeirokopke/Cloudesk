# Cloudesk - Arquitetura

## Visão geral

O Cloudesk é a plataforma de help desk AI-first da CloudWalk, construída como um **monólito modular em Rails integrado a um broker Kafka**, espelhando a estrutura de referência da CloudWalk: help desk → webhooks → broker → tópico Kafka → agente de IA, e o caminho inverso na volta.

| Aspecto | Definição |
| - | - |
| Forma | Um app Rails organizado por contextos de negócio; o broker é um papel de processo do mesmo código; agente mock e simulador de canais são serviços Python à parte |
| Estado | Um único PostgreSQL: dados, fila de jobs, tempo real e cache |
| Mensageria | Redpanda (API Kafka) entre plataforma e agente |
| Escala | Mesma imagem, processos separados por papel, escalados de forma independente |
| Empacotamento | Docker Compose, self-hosted, sobe com um comando |

Princípios que guiam o desenho:

- **Um único sistema de estado.** Todo o estado vive no Postgres, inclusive a fila de jobs; não existe Redis e não existe dual-write.
- **Atomicidade na origem.** Mensagem, auditoria e job de saída são gravados na mesma transação.
- **Toda decisão é auditada.** Cada decisão gera um `audit_event` com payload completo, regra e versão que a produziram.
- **Escala por papel, não por serviço.** Um código, vários tipos de processo.
- **Infraestrutura proporcional ao problema.** Cada componente existe porque um requisito do enunciado ou uma hipótese do experimento depende dele.

### Premissas de volume

"Milhares de atendimentos novos por dia" é traduzido nos alvos abaixo. Os números são premissas do projeto, não dados da CloudWalk.

| Parâmetro | Premissa | Como chegamos |
| - | - | - |
| Atendimentos novos por dia | 50.000 | Limite superior adotado para "milhares/dia" |
| Mensagens por atendimento | 10 | Cliente + atendente, ida e volta |
| Mensagens por dia | 500.000 | 50.000 × 10 |
| Média em horário comercial | \~8 msg/s | 70% do volume em 12 h |
| Pico sazonal | \~80 msg/s | 10× a média (Black Friday, incidente de Pix, dia de repasse) |
| Meta sustentada de projeto | 250 msg/s por 15 min | \~3× o pico, como margem |
| Latência interna (entrada → tópico Kafka) | p95 < 300 ms | Exclui o tempo de "raciocínio" do agente |
| Latência ponta a ponta (entrada → resposta no canal) | p95 < 1 s | Descontada a latência artificial do agente; 1 s é o limite em que a espera não interrompe o fluxo de quem conversa |
| Mensagens perdidas ou duplicadas para o cliente | 0 | Mesmo com falhas e reentregas |

**Unidade:** "msg/s" conta mensagens de entrada do lojista por segundo. Cada mensagem de entrada gera, no processo `web`, três requisições: o POST do canal, o GET de contexto feito pelo agente e o POST da ação do agente. A 250 msg/s, o `web` atende cerca de 750 req/s, além da entrega da resposta ao canal e dos broadcasts de tempo real.

Essas metas são as hipóteses do experimento técnico.

## Domínio

### Modelo de domínio

O agente de IA é modelado como um **atendente** igual ao humano (tipo `ai` ou `human`): ele atua como usuário da plataforma.

| Entidade | Papel |
| - | - |
| Brand | Marca/tenant (InfinitePay, JIM); escopo de todo dado |
| Team | Equipe de analistas, com skills e horário |
| Queue | Fila com SLA, capacidade, atendente inicial (IA ou humano) e fila de transbordo |
| RoutingRule | Condição → fila + prioridade; versionada e auditada |
| Contact | Lojista sintético, com identidades por canal (telefone, e-mail, id do app) |
| Conversation | O atendimento e seu estado |
| Message | Mensagem com canal, autor (cliente, IA, analista, sistema) e sequência por conversa |
| Attendant | Humano ou IA; capacidade simultânea e skills |
| Handoff | Escalação com motivo, resumo e contexto estruturado |
| AuditEvent | Registro append-only de cada decisão, com payload completo |
| CustomerMemory | Resumo das interações anteriores do lojista |

Todas as tabelas de domínio têm `brand_id`, com **Row-Level Security** no Postgres; a marca corrente é definida por transação e também segue no header Kafka. As migrações rodam com o papel dono das tabelas; a aplicação usa um papel sem privilégio de dono, para que o RLS e o bloqueio de escrita em `audit_events` valham para ela. As tabelas de infraestrutura (Solid Queue, Solid Cable e Solid Cache) não têm `brand_id` nem RLS, porque os workers processam jobs de todas as marcas; a marca de cada job segue nos argumentos dele. A tabela `brands` também fica fora do RLS, pois é lida para resolver a marca antes de ela ser definida na transação.

### Filas configuráveis pela operação

Filas e regras são dados, não código: o operador cria e edita pelo painel administrativo, sem deploy. As regras são avaliadas em ordem; a primeira que casa define fila, prioridade e SLA.

```json
{
  "name": "InfinitePay · Repasse · Alto volume",
  "when": { "brand": "infinitepay", "category": "repasse", "segment": "alto_tpv" },
  "then": { "queue": "ip-financeiro-prioritaria", "priority": 90, "sla_minutes": 15, "first_attendant": "ai" }
}
```

- **Dimensões de condição:** marca, canal, categoria, prioridade, segmento do lojista, idioma, horário.
- **Triagem:** um classificador leve (regras + palavras-chave) define categoria e prioridade na entrada; o agente pode reclassificar durante a conversa, o que dispara novo roteamento.
- **Distribuição:** atribuição por capacidade com `SELECT … FOR UPDATE SKIP LOCKED` no Postgres, evitando que dois atendentes peguem o mesmo caso.
- **Toda edição de regra gera uma nova versão** e um evento de auditoria com autor, diff e horário.

### Contrato com o agente (webhooks + Kafka)

```json
{
  "event_id": "01J9Z…",
  "type": "message.created",
  "brand": "infinitepay",
  "conversation_id": "c_8f2…",
  "sequence": 7,
  "received_at": "2026-11-13T14:02:11.482Z",
  "message": { "author": "customer", "channel": "whatsapp", "text": "Meu repasse de ontem não caiu" },
  "context_url": "/api/v1/agent/conversations/c_8f2…/context",
  "traceparent": "00-4bf9…-00f0…-01"
}
```

- **Assinatura na ida:** o webhook Core → Broker leva HMAC-SHA256 com timestamp no header; reenvios antigos são rejeitados (anti-replay).
- **Assinatura na volta:** as chamadas do Broker à API de ações do Core usam o mesmo esquema de HMAC-SHA256 com timestamp.
- **Ações do agente** (tópico de saída): `reply`, `escalate`, `categorize`, `resolve` e o registro das ferramentas consultadas. Toda ação leva `based_on_sequence`, a sequência da última mensagem que o agente considerou.
- **Entrega:** at-least-once em todo o caminho + idempotência no Core = efeito exactly-once para o cliente.
- **Falhas:** retries com backoff exponencial e jitter, tópico DLQ para mensagens problemáticas e reprocessamento pelo painel.

#### Ordem das mensagens

A chave da partição Kafka é o `conversation_id`, o que preserva a ordem em que os eventos chegam ao Kafka. Antes do Kafka, cada evento é um job do Solid Queue, e workers paralelos com retry podem entregar eventos da mesma conversa fora de ordem. Por isso a ordem não depende do transporte:

- o agente sempre decide sobre o estado mais recente da conversa, lido na `context_url`;
- se o contexto traz uma mensagem do lojista com sequência maior que a do evento recebido, o agente descarta o evento, pois o evento da mensagem mais nova produz a resposta;
- o `sequence` do evento serve para detectar atraso, não para reconstruir a conversa.

#### Idempotência

- A `Idempotency-Key` de cada ação é derivada do `event_id` de entrada e do tipo da ação. Um evento reentregue ao agente produz a mesma chave.
- O Core mantém a tabela de eventos processados com índice único; a segunda ação com a mesma chave não produz efeito e devolve o resultado da primeira.
- O Core é a única barreira de deduplicação. O agente não guarda estado, o que permite reiniciá-lo e rodar várias instâncias.

#### Ação sobre contexto desatualizado

- O Core compara `based_on_sequence` com a última mensagem do lojista na conversa. Se existe mensagem mais nova, a ação é rejeitada com `409` e a rejeição gera `audit_event`.
- O Broker trata `409` como resultado final: não reenvia e não manda para a DLQ.
- A resposta ao lojista vem da ação gerada pelo evento da mensagem mais nova.
- Uma mensagem do lojista conta como atendida quando existe uma ação aceita com `based_on_sequence` maior ou igual à sequência dela. Essa é a definição usada na reconciliação do experimento.

#### Timeout do agente

Um job recorrente varre as conversas atribuídas à IA cuja última mensagem do lojista está sem ação aceita além do SLA da fila. Para cada uma, a plataforma envia mensagem de espera ou escala para humano. Não existe timer por mensagem.

### Handoff com resumo e contexto

Na ação `escalate`, o agente envia motivo, resumo curto e contexto estruturado: intenção, entidades (ex.: id da transação sintética), ferramentas consultadas e seus retornos, tentativas feitas, sentimento, próximo passo sugerido e confiança. A plataforma muda o estado, roteia para a fila humana pela regra de escalação e notifica analistas em tempo real; o histórico completo segue anexado.

&#91;embedded content: Ciclo de vida do atendimento · 6 estados\]

Toda transição gera um evento de auditoria; uma conversa resolvida volta à triagem se o lojista escrever de novo dentro do prazo de reabertura.

### Auditoria e rastreabilidade

- `audit_events` append-only: ator, ação, alvo, antes/depois, payload do evento, motivo, regra e versão que casou, `trace_id`.
- `UPDATE` e `DELETE` bloqueados por permissão de banco e trigger.
- `traceparent` (W3C) propagado em headers HTTP e Kafka, ligando cada salto da mensagem.
- **Linha do tempo por mensagem:** cada salto carimba seu horário e o repassa adiante. O Broker registra o recebimento do webhook e a confirmação do Kafka nos headers da mensagem; o agente devolve esses carimbos e os seus próprios (consumo, ferramentas, publicação) na ação. O Core grava tudo no `audit_event` da ação. O painel monta a linha do tempo canal → Core → Broker → Kafka → agente → Broker → cliente a partir de `audit_events` e `trace_id`, sem serviço de tracing externo.

### Memória e contexto

- **Da conversa:** histórico completo disponível ao agente via `context_url`.
- **Do lojista:** resumo das conversas anteriores, atualizado no encerramento e entregue no contexto da próxima.
- **Entre canais:** identidades do mesmo lojista unificadas, para que WhatsApp e e-mail compartilhem histórico.

### Componentes simulados

- **Canais:** WhatsApp com payloads no formato da Cloud API da Meta; e-mail via Mailpit (SMTP local); chat in-app como widget web.
- **Simulador de canais:** envia mensagens sintéticas nos três formatos e recebe as respostas de saída, registrando cada uma para a reconciliação.
- **Agente mock:** determinístico por intenção, com ferramentas falsas (`consultar_transacao`, `consultar_repasse`, `consultar_taxas`, `status_maquininha`) , latência artificial configurável e modos de falha configuráveis (ver Diferenciais); modo LLM opcional com modelo aberto, registrando modelo, versão e parâmetros.
- **Dados sintéticos:** lojistas, transações e conversas gerados com seeds fixas (Faker pt\_BR e en\_US), sem nenhum dado real.

## Arquitetura

&#91;embedded content: Arquitetura · Core Rails, broker e agente mock\]

```text
Canal (chat, WhatsApp, e-mail)
  → Core Rails (web): grava mensagem + audit_event + job na mesma transação
  → jobs-webhooks: webhook assinado
  → Broker: valida, publica em agent.inbound, responde 2xx após o ack
  → Agente mock: lê contexto, decide, publica em agent.outbound
  → Broker: chama a API de ações do Core com Idempotency-Key
  → Core Rails: grava a resposta, entrega no canal, atualiza as telas
```

### Componentes

| Componente | Tecnologia | Responsabilidade |
| - | - | - |
| Core Help Desk | Rails 8 (API + Hotwire), módulos Channels, Conversations, Routing, Agents, Audit, Admin | Regras de negócio, API, chat, painel e admin |
| Banco | PostgreSQL | Atendimentos, mensagens, filas, regras, auditoria, jobs, tempo real e cache |
| Jobs | Solid Queue, no mesmo banco do app | Entrega de webhooks, varredura de SLA, resumos de memória |
| Tempo real | Action Cable / Turbo Streams sobre Solid Cable | Chat e painel do analista ao vivo |
| Cache | Solid Cache | Cache de contexto e de regras compiladas |
| E-mail de entrada | Action Mailbox + Mailpit | Canal de e-mail simulado |
| Broker | Karafka + endpoint Rack, no mesmo código e imagem do Core | Webhook → Kafka e Kafka → API de ações |
| Mensageria | Redpanda (compatível com a API Kafka) | `agent.inbound`, `agent.outbound` e DLQ |
| Agente mock | Python | Consome, lê contexto, chama ferramentas falsas, publica ação |
| Simulador de canais | Python | Gera tráfego dos três canais e recebe as respostas |
| Observabilidade | Prometheus + Grafana | Métricas, cockpit operacional e alertas |

O Broker compartilha código com o Core (schemas do contrato, assinatura HMAC), mas não acessa o banco: fala com o Core somente por HTTP, nos dois sentidos, como na estrutura de referência.

### Processos

O monólito é um único código que roda em processos distintos, cada um escalado de forma independente pelo número de réplicas no Compose. A falha de um papel não derruba os outros.

| Serviço | Comando | Escala conforme |
| - | - | - |
| `web` | Puma | requisições HTTP e conexões WebSocket |
| `jobs-webhooks` | Solid Queue, só a fila `webhooks` | volume de saída para o broker |
| `jobs-default` | Solid Queue, demais filas (SLA, memória, manutenção) | backlog de tarefas internas |
| `broker-web` | Puma com o endpoint Rack do Broker | volume de webhooks vindos do Core |
| `broker-consumer` | `karafka server` | número de partições de `agent.outbound` |
| `agent-mock` | consumidor Python | número de partições de `agent.inbound` |

Contêineres do ambiente completo: PostgreSQL, Redpanda, Mailpit, `web`, `jobs-webhooks`, `jobs-default`, `broker-web`, `broker-consumer`, `agent-mock`, simulador de canais, Prometheus e Grafana. O k6 roda só durante o experimento.

### Fluxo de uma mensagem

1. O canal simulado chama o webhook de entrada; o Core normaliza para o envelope canônico.
2. A triagem define categoria e prioridade; o Routing avalia as regras e atribui ao atendente IA da fila.
3. Numa única transação, o Core grava a mensagem, o `audit_event` e o job de webhook no Solid Queue.
4. O worker `jobs-webhooks` envia o webhook `message.created` assinado ao Broker.
5. O Broker valida a assinatura, publica em `agent.inbound` com chave `conversation_id` e responde 2xx **somente depois da confirmação do Kafka**. Sem confirmação, responde erro e o Solid Queue reenvia.
6. O agente mock consome, lê o contexto na `context_url`, consulta ferramentas falsas e publica a ação em `agent.outbound`.
7. O Broker consome e chama a API de ações do Core com `Idempotency-Key` e assinatura HMAC.
8. O Core valida `based_on_sequence`, grava a resposta, entrega no canal e atualiza a tela; em `escalate`, cria o Handoff e roteia para a fila humana.

## Decisões de design

**Postgres como único sistema de estado.** Solid Queue, Solid Cable e Solid Cache guardam jobs, mensagens de tempo real e cache no Postgres. A fila tem retries, fila de falhas e painel (Mission Control - Jobs), e sobrevive a qualquer falha que o banco sobreviva.

**Outbox implícito.** O Solid Queue usa o **mesmo banco** do app (e não o banco separado `queue` padrão do Rails 8). Gravar a mensagem e enfileirar o webhook é atômico: se o processo cai após o commit, o job já está persistido; se a transação falha, não existe job. `enqueue_after_transaction_commit` não é usado, pois apenas adia o enfileiramento sem garantir atomicidade.

**Confirmação antes do 2xx.** O Broker só confirma o webhook depois que o Kafka confirma a publicação. Uma queda do Broker em qualquer ponto resulta em reenvio pelo Solid Queue, nunca em perda.

**Deduplicação em um único lugar.** A idempotência vive no Core, com chave derivada do evento de entrada. Broker e agente são processos sem estado.

**Ordem pelo estado, não pelo transporte.** O agente decide sobre o contexto mais recente e o Core rejeita ação desatualizada. O sistema é correto mesmo quando eventos da mesma conversa chegam fora de ordem.

**Broker como papel do mesmo código.** O contrato e a assinatura têm uma única implementação em Ruby, e o Broker segue como processo isolado, com fronteira HTTP.

**Broker em dois processos.** O Broker roda como `broker-web` e `broker-consumer`, da mesma imagem. O `broker-web` é um Puma que serve o endpoint Rack e publica em `agent.inbound`; o `broker-consumer` é o `karafka server`, que consome `agent.outbound` e chama a API de ações do Core. Cada sentido escala pela sua própria carga (volume de webhooks na ida, partições na volta), e a queda de um não interrompe o outro.

**Rastreabilidade a partir da auditoria.** A linha do tempo de cada mensagem sai de `audit_events`, que o enunciado já exige. Métricas agregadas ficam no Prometheus.

**Escala por papel de processo.** Uma imagem, um repositório e um deploy, com `web`, workers e broker escalando separadamente conforme sua própria carga.

**Dimensionamento do Postgres.** Por mensagem de entrada, o banco recebe: a mensagem do lojista, a resposta do atendente, os `audit_events` de cada decisão, as linhas do job de webhook nas tabelas do Solid Queue (enfileiramento, reserva e conclusão), o registro de idempotência e os broadcasts do Solid Cable. O total de transações por segundo na meta de 250 msg/s é uma das medidas do experimento, não uma premissa.

- Índices parciais nas filas e nas conversas abertas.
- Aplicação conectada diretamente ao Postgres, com pool dimensionado por processo.

### Robustez

- **Reentrega:** tabela de eventos processados com índice único; duplicatas são descartadas no Core.
- **Ordem:** agente decide pelo contexto mais recente; o Core rejeita ação baseada em contexto desatualizado.
- **Broker ou Kafka fora do ar:** o Solid Queue reenvia com backoff; ao esgotar, o job vai para a fila de falhas com botão de reprocessar no painel.
- **Processo cai no meio da operação:** nada se perde, porque mensagem e job foram gravados na mesma transação e o Broker só confirma após o ack do Kafka.
- **Agente sem resposta:** a varredura de SLA envia mensagem de espera ou escala para humano.
- **Picos:** `web` e `jobs-webhooks` escalam horizontalmente; webhooks em fila dedicada; limite de taxa por marca.

### Limites conhecidos

- O Postgres concentra todo o estado e é o gargalo esperado de escala.
- O isolamento entre marcas é lógico (`brand_id` + RLS), não físico.
- `messages` e `audit_events` são tabelas únicas, sem particionamento; o crescimento contínuo exige particionar (ver Evolução).
- Não há pooler de conexões; o número de processos é limitado pelas conexões do Postgres.
- A linha do tempo depende dos relógios dos contêineres, que no ambiente local são o mesmo relógio da máquina.

## Experimento técnico: carga + falhas

### Hipóteses

Cada hipótese é avaliada separadamente, para que o resultado de uma não esconda o de outra.

| # | Hipótese | Medida |
| - | - | - |
| H1 | A plataforma sustenta 250 msg/s de entrada por 15 min sem acúmulo crescente de backlog | Profundidade do Solid Queue e lag do Kafka ao longo do teste |
| H2 | Nessa carga, a latência da entrada até a confirmação do Kafka tem p95 < 300 ms | Do recebimento HTTP no Core (`received_at`) até o ack do Kafka no Broker |
| H3 | Com o broker reiniciado e um worker morto durante o teste, nenhuma mensagem é perdida nem duplicada para o cliente | Reconciliação entre mensagens enviadas e respostas recebidas |
| H4 | Nessa carga, a latência ponta a ponta tem p95 < 1 s, descontada a latência artificial do agente | Do recebimento HTTP no Core (`received_at`) até a entrega da resposta no canal, menos a latência artificial configurada no agente mock |

A H4 mede a latência que o lojista percebe; a H2 mede só o trecho interno até o Kafka.

### Método

- **Carga:** k6 chama diretamente os endpoints de entrada de WhatsApp e chat, em degraus de 1×, 3×, 10× e 30× a média. O e-mail é coberto por teste funcional, fora da carga.
- **Falhas:** `docker restart` no `broker-web` e no `broker-consumer` e `docker kill` em um worker `jobs-webhooks` em instantes definidos do teste.
- **Reconciliação:** cada mensagem enviada tem identificador único; o simulador de canais recebe as respostas de saída e as registra. Perdida é a mensagem do lojista sem ação aceita que a cubra (ver "Ação sobre contexto desatualizado"); duplicada é a resposta entregue mais de uma vez ao canal.
- **Métricas:** Prometheus coleta latência por salto, profundidade do Solid Queue, TPS e conexões do Postgres e lag de consumo do Kafka.
- **Análise:** pandas e Plotly, com as condições de cada execução registradas.

### Limitações

- O gerador de carga roda na mesma máquina do sistema medido e disputa CPU com ele; os valores de latência são um limite pessimista para esse hardware e não se transferem para produção.
- Hardware local difere de produção; no Windows, os contêineres rodam sobre WSL2.
- O agente mock tem latência artificial e decisão determinística.
- A distribuição de mensagens é sintética.
- Um único Postgres e um único nó Redpanda.
- O canal de e-mail não participa da carga.

## Cobertura dos requisitos

| Requisito | Como é atendido |
| - | - |
| Multicanal simulado | Simulador de WhatsApp (formato Cloud API), e-mail via Mailpit, widget de chat; envelope canônico |
| Filas configuráveis e editáveis | Queue + RoutingRule como dados, editadas no admin, versionadas e auditadas |
| Interface de conversa | Chat web em tempo real entre cliente e atendente (IA ou analista) |
| Painel do analista | Fila de escalas, briefing do handoff, histórico completo e memória do lojista |
| Integração webhooks + broker | Webhooks assinados → Broker → Kafka → agente, e o caminho inverso |
| Triagem, priorização e distribuição | Classificador na entrada + regras + atribuição por capacidade; IA como primeiro nível |
| Handoff com resumo e contexto | Ação `escalate` com resumo e contexto estruturado; histórico preservado |
| Rastreabilidade e auditoria | `audit_events` imutável, linha do tempo por mensagem e `traceparent` em HTTP e Kafka |
| Memória e contexto | Histórico da conversa, resumo do lojista e identidade unificada entre canais |
| Agente simulado | Mock determinístico com ferramentas falsas; modo LLM opcional registrado |
| Experimento técnico | Quatro hipóteses, método e limitações descritos acima |
| Empacotamento self-hosted | Docker Compose com todos os serviços |

## Diferenciais

Cinco diferenciais fazem parte do escopo, escolhidos por esforço baixo e por aparecerem na demonstração.

**1. Briefing de handoff avaliado pelo analista**

O handoff chega como cartão: problema em uma frase, o que a IA tentou, ferramentas e retornos, sentimento, próximo passo sugerido e confiança. O analista marca o briefing como útil ou não, o que mede a qualidade do handoff e o tempo até a primeira resposta humana.

**2. Cockpit operacional em tempo real**

Dashboard Grafana com profundidade por fila, casos em risco de SLA, taxa de contenção da IA, motivos de escalação (Pareto), lag do Kafka, backlog do Solid Queue e alertas.

**3. Disjuntor de IA**

Por fila ou marca, um botão no admin passa todas as novas conversas para humanos na hora. O acionamento gera `audit_event` com autor e motivo.

**4. "Por que caiu aqui?"**

Em cada conversa, a tela mostra a regra e a versão que definiram fila, prioridade e SLA. A informação vem do `audit_event` de roteamento, que grava a regra e a versão que casaram. Reforça a rastreabilidade e as filas configuráveis.

**5. Modos de falha do agente mock**

Por configuração, o agente mock atrasa, não responde, publica a mesma ação duas vezes ou envia ação desatualizada. Cada modo exercita um caminho da plataforma: a varredura de SLA (timeout), a idempotência no Core e a rejeição com `409`. Reforça a robustez diante de falhas e reentregas e permite demonstrá-la.

## Pontos em aberto

| # | Ponto | Afeta |
| - | - | - |
| 1 | Login e perfis dos usuários do painel e do admin (analista, operador) | Autor das edições de regra na auditoria; painel do analista |
| 2 | Regra do timeout: quando enviar mensagem de espera e quando escalar | Varredura de SLA |
| 3 | Ligação entre Mailpit e Action Mailbox (ingress usado) | Canal de e-mail |

## Evolução

**Escala e operação**

- **Particionamento mensal** de `messages` e `audit_events`, com manutenção automática de partições.
- **PgBouncer** em modo `transaction` para o `web` e `session` para os workers, quando o número de processos exigir.
- **Réplica de leitura** com o multi-database do Rails para painel, histórico e relatórios.
- **Sharding por `brand_id`** e, depois, **células por marca**: isolamento físico e residência de dados.
- **Deploy com Kamal** em servidores próprios.
- **Tracing distribuído** com OpenTelemetry e Jaeger ou Tempo.
- **Laboratório de caos** com Toxiproxy: latência e queda de rede injetadas em cenários repetíveis.

**Eventos**

- **Tópico `helpdesk.events`** com os eventos de domínio, para consumidores de analytics, QA e copiloto lerem sem tocar no Core.
- **Replay de `audit_events`** reconstruindo tabelas de leitura, com checksum de verificação.
- **Auditoria à prova de adulteração:** cadeia de hash por conversa e verificador.

**Operação e filas**

- **Editor de filas com simulação:** dry-run da regra sobre as últimas N conversas, aprovação por duas pessoas e rollback.
- **Priorização dinâmica:** score com aging, risco de SLA, segmento e sentimento.
- **Simulador sazonal com personas** e incidentes injetáveis.
- **Guardrails por política e abertura automática do disjuntor** por taxa de erro ou de escalação.

**IA e atendimento**

- **Detecção de incidentes em massa** por agrupamento de mensagens recentes.
- **Copiloto do analista** após o handoff.
- **Memória semântica** com pgvector e casos similares.
- **Shadow mode e canário** de versões do agente.
- **Cloudesk como servidor MCP.**

**Governança**

- **Privacidade por design:** mascaramento de dados pessoais antes do agente e dos logs, retenção por marca e crypto-shredding.

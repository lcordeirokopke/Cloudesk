# Cloudesk — Arquitetura

## Visão geral

O Cloudesk é a plataforma de help desk AI-first da CloudWalk, construída como um **monólito modular em Rails integrado a um broker Kafka**, espelhando a estrutura de referência da CloudWalk: help desk → webhooks → broker → tópico Kafka → agente de IA, e o caminho inverso na volta.

| Aspecto | Definição |
| --- | --- |
| Forma | Um app Rails organizado por contextos de negócio, com broker e agente mock como serviços à parte |
| Estado | Um único PostgreSQL: dados, fila de jobs, tempo real e cache |
| Mensageria | Redpanda (API Kafka) entre plataforma e agente, e um tópico de eventos de domínio para replay |
| Escala | Mesma imagem, processos separados por papel, escalados de forma independente |

Princípios que guiam o desenho:

- **Um único sistema de estado.** Todo o estado vive no Postgres, inclusive a fila de jobs; não existe Redis e não existe dual-write.
- **Atomicidade na origem.** Mensagem, auditoria e jobs de saída são gravados na mesma transação.
- **Eventos reprodutíveis.** Toda decisão gera um evento com payload completo, que pode ser relido para reconstruir o estado derivado.
- **Escala por papel, não por serviço.** Um código, vários tipos de processo.

### Premissas de volume

"Milhares de atendimentos novos por dia" é traduzido nos alvos abaixo.

| Parâmetro | Premissa | Como chegamos |
| --- | --- | --- |
| Atendimentos novos por dia | 50.000 | Limite superior de "milhares/dia" |
| Mensagens por atendimento | 10 | Cliente + atendente, ida e volta |
| Mensagens por dia | 500.000 | 50.000 × 10 |
| Média em horário comercial | \~8 msg/s | 70% do volume em 12 h |
| Pico sazonal | \~80 msg/s | 10× a média (Black Friday, incidente de Pix, dia de repasse) |
| Meta sustentada de projeto | 250 msg/s por 15 min | \~3× o pico, como margem |
| Latência interna (entrada → tópico Kafka) | p95 < 300 ms | Exclui o tempo de "raciocínio" do agente |
| Mensagens perdidas ou duplicadas para o cliente | 0 | Mesmo com falhas e reentregas |

Essas metas são a hipótese do experimento técnico.

## Domínio

### Modelo de domínio

O agente de IA é modelado como um **atendente** igual ao humano (tipo `ai` ou `human`): ele atua como usuário da plataforma.

| Entidade | Papel |
| --- | --- |
| Brand | Marca/tenant (InfinitePay, JIM); escopo de todo dado |
| Team | Equipe de analistas, com skills e horário |
| Queue | Fila com SLA, capacidade, atendente inicial (IA ou humano) e fila de transbordo |
| RoutingRule | Condição → fila + prioridade; versionada e auditada |
| Contact | Lojista sintético, com identidades por canal (telefone, e-mail, id do app) |
| Conversation | O atendimento e seu estado |
| Message | Mensagem com canal, autor (cliente, IA, analista, sistema) e sequência |
| Attendant | Humano ou IA; capacidade simultânea e skills |
| Handoff | Escalação com motivo, resumo e contexto estruturado |
| AuditEvent | Registro append-only de cada decisão, com payload completo (base do replay) |
| CustomerMemory | Resumo das interações anteriores do lojista |

Todas as tabelas têm `brand_id`, com **Row-Level Security** no Postgres; a marca também segue no header Kafka.

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
- **Triagem:** um classificador leve (regras + palavras-chave no mock) define categoria e prioridade na entrada; o agente pode reclassificar durante a conversa, o que dispara novo roteamento.
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
  "message": { "author": "customer", "channel": "whatsapp", "text": "Meu repasse de ontem não caiu" },
  "context_url": "/api/v1/agent/conversations/c_8f2…/context",
  "traceparent": "00-4bf9…-00f0…-01"
}
```

- **Assinatura:** HMAC-SHA256 com timestamp no header, rejeitando reenvios antigos (anti-replay).
- **Ordem:** a chave da partição Kafka é o `conversation_id`, então mensagens da mesma conversa chegam em ordem.
- **Ações do agente** (tópico de saída): `reply`, `escalate`, `categorize`, `resolve` e o registro das ferramentas consultadas.
- **Entrega:** at-least-once em todo o caminho + idempotência por `event_id`/`Idempotency-Key` = efeito exactly-once para o cliente.
- **Falhas:** retries com backoff exponencial e jitter, tópico DLQ para mensagens problemáticas e reprocessamento pelo painel.
- **Timeout do agente:** se a IA não responde dentro do SLA da fila, a plataforma envia mensagem de espera ou escala para humano.

### Handoff com resumo e contexto

Na ação `escalate`, o agente envia motivo, resumo curto e contexto estruturado: intenção, entidades (ex.: id da transação sintética), ferramentas consultadas e seus retornos, tentativas feitas e sentimento. A plataforma muda o estado, roteia para a fila humana pela regra de escalação e notifica analistas em tempo real; o histórico completo segue anexado.

&#91;embedded content: Ciclo de vida do atendimento · 6 estados\]

Toda transição gera um evento de auditoria; uma conversa resolvida volta à triagem se o lojista escrever de novo dentro do prazo de reabertura.

### Auditoria e rastreabilidade

- `audit_events` append-only: ator, ação, alvo, antes/depois, payload do evento, motivo, regra e versão que casou, `trace_id`.
- `UPDATE` e `DELETE` bloqueados por permissão de banco e trigger.
- `traceparent` (W3C) propagado em headers HTTP e Kafka, ligando cada salto da mensagem; OpenTelemetry instrumentado em todos os serviços.
- Os eventos também são publicados no tópico `helpdesk.events`, permitindo replay.

### Memória e contexto

- **Da conversa:** histórico completo disponível ao agente via `context_url`.
- **Do lojista:** resumo das conversas anteriores, atualizado no encerramento e entregue no contexto da próxima.
- **Entre canais:** identidades do mesmo lojista unificadas, para que WhatsApp e e-mail compartilhem histórico.

### Componentes simulados

- **Canais:** WhatsApp com payloads no formato da Cloud API da Meta; e-mail via Mailpit (SMTP local); chat in-app como widget web.
- **Agente mock:** determinístico por intenção, com ferramentas falsas (`consultar_transacao`, `consultar_repasse`, `consultar_taxas`, `status_maquininha`); modo LLM opcional com modelo aberto, registrando modelo, versão e parâmetros.
- **Dados sintéticos:** lojistas, transações e conversas gerados com seeds fixas (Faker pt\_BR e en\_US), sem nenhum dado real.

## Arquitetura

&#91;embedded content: Arquitetura · Core Rails, broker e agente mock\]

O Core grava no Postgres e, na mesma transação, enfileira o webhook e o evento de domínio no Solid Queue; do Broker para baixo, o caminho até o agente e de volta segue a referência da CloudWalk.

### Componentes

| Componente | Tecnologia | Responsabilidade |
| --- | --- | --- |
| Core Help Desk | Rails 8 (API + Hotwire), módulos Channels, Conversations, Routing, Agents, Audit, Admin | Regras de negócio, API, chat, painel e admin |
| Banco | PostgreSQL (+ PgBouncer) | Atendimentos, mensagens (particionadas por mês), filas, regras, auditoria, jobs, tempo real e cache |
| Jobs | Solid Queue, no mesmo banco do app | Entrega de webhooks, publicação de eventos, timers de SLA, resumos de memória |
| Tempo real | Action Cable / Turbo Streams sobre Solid Cable | Chat e painel do analista ao vivo |
| Cache | Solid Cache | Cache de contexto e de regras compiladas |
| E-mail de entrada | Action Mailbox + Mailpit | Canal de e-mail simulado |
| Broker | Serviço Ruby com Karafka + endpoint Rack | Webhook → Kafka e Kafka → API da plataforma |
| Mensageria | Redpanda (compatível com a API Kafka) | `agent.inbound`, `agent.outbound`, DLQ e `helpdesk.events` |
| Agente mock | Python | Consome, decide, chama ferramentas falsas, publica ação |
| Simulador de canais | Python | Gera tráfego de WhatsApp, chat e e-mail |
| Observabilidade | OpenTelemetry, Prometheus, Grafana, Jaeger/Tempo | Traces, métricas e cockpit |
| Empacotamento | Docker Compose; Kamal para deploy self-hosted | Sobe tudo com um comando |

### Processos

O monólito é um único código que roda em processos distintos, cada um escalado de forma independente (`docker compose up --scale <serviço>=N`). A falha de um papel não derruba os outros.

| Serviço | Comando | Escala conforme |
| --- | --- | --- |
| `web` | Puma | requisições HTTP e conexões WebSocket |
| `jobs-webhooks` | Solid Queue, só filas `webhooks` e `events` | volume de saída para o broker |
| `jobs-default` | Solid Queue, demais filas (SLA, memória, manutenção) | backlog de tarefas internas |
| `broker` | `karafka server` + endpoint Rack | número de partições Kafka |
| `agent-mock` | consumidor Python | número de partições de `agent.inbound` |

### Fluxo de uma mensagem

1. O canal simulado chama o webhook de entrada; o Core normaliza para o envelope canônico.
2. A triagem define categoria e prioridade; o Routing avalia as regras e atribui ao atendente IA da fila.
3. Numa única transação, o Core grava a mensagem, o `audit_event` e os jobs de webhook e de evento no Solid Queue.
4. O worker `jobs-webhooks` envia o webhook `message.created` assinado ao Broker e publica o evento em `helpdesk.events`.
5. O Broker valida a assinatura, responde 2xx e publica em `agent.inbound` com chave `conversation_id`.
6. O agente mock consome, consulta ferramentas falsas e publica a ação em `agent.outbound`.
7. O Broker consome e chama a API de ações do Core com `Idempotency-Key`.
8. O Core grava a resposta, entrega no canal e atualiza a tela; em `escalate`, cria o Handoff e roteia para a fila humana.

## Decisões de design

**Postgres como único sistema de estado.** Solid Queue, Solid Cable e Solid Cache guardam jobs, mensagens de tempo real e cache no Postgres. A fila tem retries, fila de falhas e painel (Mission Control – Jobs), e sobrevive a qualquer falha que o banco sobreviva.

**Outbox implícito.** O Solid Queue usa o **mesmo banco** do app (e não o banco separado `queue` padrão do Rails 8). Gravar a mensagem e enfileirar o webhook é atômico: se o processo cai após o commit, o job já está persistido; se a transação falha, não existe job. `enqueue_after_transaction_commit` não é usado, pois apenas adia o enfileiramento sem garantir atomicidade.

**Replay de eventos.** Duas camadas:
- `audit_events` guarda o payload completo de cada evento com `id` monotônico. O comando `rake events:replay FROM=<id>` reconstrói as tabelas de leitura (contadores, SLA do painel, memória).
- Cada evento é publicado em `helpdesk.events` (chave `conversation_id`, retenção longa). Novos consumidores (analytics, copiloto, QA) leem o histórico desde o offset 0 sem tocar no Core.

**Escala por papel de processo.** Uma imagem, um repositório e um deploy, com `web`, workers e broker escalando separadamente conforme sua própria carga.

**Dimensionamento do Postgres.** Na meta de 250 msg/s, com cerca de 5 escritas por mensagem (mensagem, auditoria, jobs), a carga fica na casa de 1–2 mil TPS, dentro da capacidade de um único Postgres bem indexado; o experimento mede esse valor.
- Particionamento mensal de `messages` e `audit_events`; índices parciais nas filas.
- PgBouncer em modo `transaction` para o `web` e em modo `session` (ou conexão direta) para os workers do Solid Queue, que usam `SKIP LOCKED` e conexões longas.
- Réplica de leitura com o multi-database do Rails (`connects_to` com troca automática de papel) para painel, histórico e relatórios, ativada quando a carga de leitura exigir.

### Robustez

- **Reentrega:** tabela de eventos processados com índice único; duplicatas são descartadas no Core e no agente.
- **Ordem:** partição por conversa e número de sequência; o Core rejeita ação baseada em contexto desatualizado.
- **Broker ou Kafka fora do ar:** o Solid Queue reenvia com backoff; ao esgotar, o job vai para a fila de falhas com botão de reprocessar no painel.
- **Processo cai no meio da operação:** nada se perde, porque mensagem e job foram gravados na mesma transação.
- **Picos:** `web` e `jobs-webhooks` escalam horizontalmente; webhooks em fila dedicada; limite de taxa por marca.

### Limites conhecidos

- O Postgres concentra todo o estado e é o gargalo esperado de escala.
- O isolamento entre marcas é lógico (`brand_id` + RLS), não físico.
- A consistência é forte dentro do Core e eventual para consumidores de `helpdesk.events`.

## Experimento técnico: carga + falhas

- **Hipótese:** a plataforma sustenta 250 msg/s por 15 min com p95 < 300 ms da entrada até o tópico Kafka, sem perda nem duplicação, mesmo com o broker reiniciado e um worker morto durante o teste.
- **Método:** k6 gerando tráfego pelo simulador de canais em degraus (1×, 3×, 10× e 30× a média); Toxiproxy injetando latência e queda; métricas no Prometheus (incluindo TPS e conexões do Postgres e profundidade do Solid Queue); análise em pandas e Plotly. Ao final, um replay de `audit_events` do zero tem o checksum comparado com as tabelas de leitura.
- **Limitações:** hardware local difere de produção; o agente mock tem latência artificial; a distribuição de mensagens é sintética; um único Postgres e um único broker Redpanda.

## Cobertura dos requisitos

| Requisito | Como é atendido |
| --- | --- |
| Multicanal simulado | Simulador de WhatsApp (formato Cloud API), e-mail via Mailpit, widget de chat; envelope canônico |
| Filas configuráveis e editáveis | Queue + RoutingRule como dados, editadas no admin, versionadas e auditadas |
| Interface de conversa | Chat web em tempo real entre cliente e atendente (IA ou analista) |
| Painel do analista | Fila de escalas, briefing do handoff, histórico completo e memória do lojista |
| Integração webhooks + broker | Webhooks assinados → Broker → Kafka → agente, e o caminho inverso |
| Triagem, priorização e distribuição | Classificador na entrada + regras + atribuição por capacidade; IA como primeiro nível |
| Handoff com resumo e contexto | Ação `escalate` com resumo e contexto estruturado; histórico preservado |
| Rastreabilidade e auditoria | `audit_events` imutável e reprodutível + `traceparent` em HTTP e Kafka |
| Memória e contexto | Histórico da conversa, resumo do lojista e identidade unificada entre canais |
| Agente simulado | Mock determinístico com ferramentas falsas; modo LLM opcional registrado |
| Experimento técnico | Hipótese, método e limitações descritos acima |

## Diferenciais

&#91;embedded content: Diferenciais por impacto e esforço · 15 itens\]

### Confiabilidade e rastreabilidade

**1. Linha do tempo de trace ponta a ponta** · Impacto alto · Esforço médio

O `traceparent` W3C propagado em HTTP e Kafka alimenta, no painel, a linha do tempo de cada mensagem: canal → Core → Broker → Kafka → agente → Broker → cliente, com a latência de cada salto (Jaeger ou Grafana Tempo por trás). Transforma auditoria em evidência navegável e mostra onde o tempo é gasto.

**2. Laboratório de caos e reentregas** · Impacto alto · Esforço médio

Cenários scriptados com Toxiproxy e Docker: broker derrubado, Kafka lento, webhook entregue duas vezes, agente que não responde, worker morto, Postgres reiniciado. Falhas, reentregas e picos viram testes automatizados e repetíveis, com placar de mensagens perdidas e duplicadas.

**3. Auditoria à prova de adulteração** · Impacto médio · Esforço baixo

Cada evento guarda o hash do anterior (cadeia por conversa) e um verificador aponta qualquer alteração. Cada decisão mostra a regra, a versão e a justificativa do agente que a produziram: auditoria verificável, não apenas registrada.

### Operação e filas

**4. Editor de filas com simulação, versionamento e rollback** · Impacto alto · Esforço médio

Antes de publicar uma regra, o operador roda um dry-run sobre as últimas N conversas e vê o impacto (ex.: quantos casos mudariam de fila). Cada versão tem diff, aprovação por duas pessoas e rollback em um clique.

**5. Priorização dinâmica com aging e risco de SLA** · Impacto médio · Esforço médio

Score que combina prioridade base, tempo até estourar o SLA, tempo de espera, segmento do lojista e sentimento, com atribuição por skill e capacidade — um distribuidor de contact center (ACD), não uma fila FIFO.

**6. Cockpit operacional em tempo real** · Impacto alto · Esforço baixo

Dashboard Grafana com profundidade por fila, casos em risco de SLA, taxa de contenção da IA, motivos de escalação (Pareto), lag do Kafka, backlog do Solid Queue e alertas.

**7. Simulador de tráfego sazonal com personas** · Impacto alto · Esforço médio

Gerador com personas de lojista (novo, alto volume, com crédito ativo, irritado), curvas sazonais (Black Friday, dia de repasse, madrugada) e incidentes injetáveis, com seeds fixas. Um LLM pode gerar diálogos variados offline, salvos como dataset.

### IA e atendimento

**8. Briefing de handoff avaliado pelo analista** · Impacto alto · Esforço baixo

O handoff chega como cartão: problema em uma frase, o que a IA tentou, ferramentas e retornos, sentimento, próximo passo sugerido e confiança. O analista marca o briefing como útil ou não, o que mede a qualidade do handoff e o tempo até a primeira resposta humana.

**9. Disjuntor de IA e guardrails por política** · Impacto alto · Esforço baixo

Por fila ou marca: botão que passa tudo para humanos na hora; políticas do que a IA faz sozinha (ex.: só informar em "crédito"); abertura automática se a taxa de erro ou de escalação da IA passar de um limite.

**10. Detecção de incidentes em massa** · Impacto alto · Esforço alto

Agrupamento das mensagens recentes (embeddings ou n-gramas) numa janela deslizante detecta picos de um mesmo assunto, como "Pix não caiu". A plataforma abre um incidente, agrupa as conversas, sobe a prioridade e sugere resposta padrão.

**11. Copiloto do analista após o handoff** · Impacto médio · Esforço médio

Depois da escalação, a IA segue como copiloto: sugere respostas e ações que o analista aceita, edita ou descarta, medido pela taxa de aceitação.

**12. Memória semântica e casos similares** · Impacto médio · Esforço médio

Embeddings (pgvector) das conversas resolvidas: agente e analista recebem casos parecidos e como foram resolvidos, além do resumo do lojista.

**13. Shadow mode e canário de versões do agente** · Impacto médio · Esforço alto

Uma nova versão do agente recebe cópia do tráfego sem responder ao cliente; suas decisões são comparadas à versão atual antes de liberar uma porcentagem da fila.

### Governança e abertura

**14. Privacidade por design (LGPD)** · Impacto alto · Esforço médio

Mascaramento de CPF, CNPJ, cartão e telefone antes de enviar ao agente e aos logs; retenção por marca; crypto-shredding (chave por lojista) para pedidos de exclusão sem quebrar a auditoria; registro de quem viu dados pessoais.

**15. Cloudesk como servidor MCP** · Impacto médio · Esforço médio

Além de webhooks e Kafka, as capacidades da plataforma (ler conversa, responder, escalar, classificar, buscar similares) são expostas via Model Context Protocol, para que qualquer agente compatível opere na plataforma sem integração sob medida.

## Evolução

- **Sharding por `brand_id`** e, depois, **células por marca**: isolamento físico, residência de dados (LGPD no Brasil, regras próprias nos EUA) e canário de agente por marca.
- **Conector Kafka-a-Kafka** entre `helpdesk.events` e o broker, eliminando um salto.
- **Novos consumidores** de `helpdesk.events` (analytics, QA de atendimento, copiloto) sem tocar no Core.

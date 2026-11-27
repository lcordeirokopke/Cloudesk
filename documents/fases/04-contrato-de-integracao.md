# Cloudesk · Contrato de integração

## O que é

O contrato de integração define tudo o que trafega entre o Core, o Broker e o agente de IA: o corpo de cada mensagem, os headers de cada tópico Kafka, as respostas da API de ações, o contexto da conversa, a assinatura das chamadas HTTP e a chave de idempotência.

Ele fica em `contracts/v1/`, na raiz do repositório, como dados: JSON Schemas, exemplos válidos e inválidos e vetores de teste. O Ruby (Core e Broker) e o Python (agente) leem os mesmos arquivos, e os testes dos dois lados afirmam as mesmas coisas. Os três componentes são construídos e testados de forma independente, e um não quebra o outro sem que um teste de contrato falhe.

## Onde fica no fluxo

```text
Core ── webhook message.created ──► Broker ──► agent.inbound ──► agente
  ▲      (assinado, BROKER_WEBHOOK_SECRET)     headers: brand, traceparent, broker_received_at
  │                                                                    │
  │◄── GET context_url (assinado, AGENT_CONTEXT_SECRET) ── resposta: context
  │                                                                    │
  │◄── POST /api/v1/agent/actions ◄── Broker ◄── agent.outbound ◄── ação
       (assinado, AGENT_ACTIONS_SECRET,           headers: brand, traceparent
        Idempotency-Key)                          falha final: agent.dlq com headers de diagnóstico
       resposta: action-response
```

Cada seta tem um schema; cada chamada HTTP tem uma assinatura com segredo próprio.

## Por que existe e que valor gera

**Componentes independentes.** O Core, o Broker e o agente têm processos, linguagens e ciclos próprios. O contrato é a única coisa que eles compartilham: os testes dos dois lados conferem as peças contra os mesmos schemas, e uma mudança incompatível aparece como teste de contrato falhando, não como erro em produção.

**Uma só fonte para duas linguagens.** Schemas, exemplos e vetores ficam em arquivos, não em código. Ruby e Python não traduzem regras um do outro; eles leem o mesmo arquivo. Os vetores de assinatura são conferidos pelas duas implementações e pelo `openssl`.

**Segurança das chamadas.** Toda chamada HTTP entre os componentes é assinada com HMAC-SHA256 e timestamp, com um segredo por chamada. Uma assinatura capturada não vale em outro endpoint, não vale depois de 5 minutos e não vale com outro corpo. O agente, que só lê o contexto, não tem o segredo para forjar uma ação.

**Idempotência de ponta a ponta.** A `Idempotency-Key` deriva do evento de entrada e do tipo da ação. Um evento reentregue ao agente produz a mesma chave, e o Core reconhece a repetição sem que Broker e agente guardem estado.

**Rastreabilidade embutida.** O `traceparent` W3C viaja em todas as peças, e cada salto carimba o seu horário: o Broker no header Kafka, o Kafka no timestamp do registro, o agente no corpo da ação. O Core recebe todos os carimbos na ação e monta a linha do tempo de cada mensagem só a partir da auditoria.

**Decisões de IA auditáveis.** A ação carrega as ferramentas consultadas com entradas, saídas e horários e, quando o agente informa, o modelo que produziu a decisão, com versão e parâmetros. O `escalate` só é aceito com o briefing completo.

## Como funciona

### Organização

```text
contracts/v1/
├── schemas/                          um JSON Schema por peça
│   ├── webhook.message-created.json
│   ├── kafka.inbound-headers.json
│   ├── kafka.outbound-headers.json
│   ├── kafka.dlq-headers.json
│   ├── action.json
│   ├── action-response.json
│   └── context.json
├── examples/<schema>/valid/*.json    exemplos que o schema aceita
├── examples/<schema>/invalid/*.json  exemplos que o schema recusa
├── signature-vectors.json            entradas e assinaturas esperadas
└── idempotency-key-vectors.json      entradas e chaves esperadas
```

- Os schemas seguem o JSON Schema draft 2020-12, validados com `json_schemer` no Ruby e `jsonschema` no Python.
- Cada schema é autossuficiente: os padrões comuns (UUID, horário, `traceparent`, marca) se repetem em `$defs` de cada arquivo, e as duas bibliotecas validam sem resolver referências externas.
- Os formatos são conferidos por `pattern`, e não por `format`: no draft 2020-12, `format` é anotação por padrão, e cada biblioteca decide se o confere.
- Os schemas são estritos: campo fora do contrato é recusado, e na ação o campo de um tipo em outro tipo também (por exemplo, `category` em um `reply`).
- Campos em inglês, `snake_case`; horários em ISO 8601, UTC, com milissegundos.

O código Ruby do contrato fica em `core/lib/contract/` e não acessa o banco, porque o Broker o usa e não fala com o PostgreSQL:

| Arquivo | Função |
| - | - |
| `schemas.rb` | Carrega e valida os schemas |
| `signature.rb` | Assina e verifica as chamadas |
| `idempotency_key.rb` | Deriva a `Idempotency-Key` |
| `message_created.rb` | Monta o corpo do webhook a partir do envelope canônico do evento |

No Python, a assinatura fica em `agent_mock/src/agent_mock/signature.py`. O simulador de canais tem uma cópia dela em `channel_simulator/src/channel_simulator/signature.py`, usada na entrada JSON do chat, e o kit de conformidade do agente tem a própria conferência em `agent_conformance/src/agent_conformance/signature.py`, usada pelo Core falso.

### Validação em produção

| Peça | Quem valida contra o schema em produção |
| - | - |
| `webhook.message-created` | O Core, ao montar o corpo (`Contract::MessageCreated.build`), e o Broker, ao receber o webhook |
| `kafka.inbound-headers` | O Broker, ao gravar os headers em `agent.inbound` |
| `kafka.dlq-headers` | O `broker-consumer`, ao gravar os headers de diagnóstico em `agent.dlq` |
| `action` | O Core, na API de ações (`Agents::ActionProcessor`); o `broker-consumer` não valida a ação, só deriva dela a `Idempotency-Key` |
| `kafka.outbound-headers`, `action-response`, `context` | Ninguém; são conferidos só nos testes |

O agente não usa os schemas em produção (o `jsonschema` fica só no extra `test`): ele confere os campos do evento e dos headers de `agent.inbound` com checagens próprias e, no contexto, só a forma de `conversation` e `messages`. As peças que ninguém valida em produção são conferidas nos testes do lado que as emite: os specs do Core para `context` e `action-response`, e o kit de conformidade para a ação e os headers publicados pelo agente.

### Webhook `message.created`

Schema `webhook.message-created`. É o corpo do webhook do Core ao Broker e, sem nenhuma alteração, o valor da mensagem Kafka em `agent.inbound`, com chave `conversation_id`.

| Campo | Conteúdo |
| - | - |
| `event_id` | `event_id` do `audit_event` da mensagem |
| `type` | `message.created` |
| `brand` | Slug da marca |
| `conversation_id` | UUID da conversa |
| `sequence` | Sequência da mensagem na conversa, a partir de 1 |
| `received_at` | Horário em que o Core recebeu a mensagem do canal |
| `message` | `author` (`customer`, `ai`, `analyst`, `system`), `channel` (`chat`, `whatsapp`, `email`) e `text` |
| `context_url` | `/api/v1/agent/brands/<brand>/conversations/<conversation_id>/context` |
| `traceparent` | Contexto de trace W3C |

`Contract::MessageCreated.build` monta o corpo a partir do envelope canônico gravado no `audit_event`: os campos do envelope, a `message` do `payload` e a `context_url`, e valida o resultado contra o schema. A `context_url` leva o slug da marca porque o RLS exige a marca antes da leitura da conversa, e a marca no caminho entra no texto assinado pelo agente.

### Headers das mensagens Kafka

| Tópico | Schema | Headers |
| - | - | - |
| `agent.inbound` | `kafka.inbound-headers` | `brand`, `traceparent` e `broker_received_at`, o horário em que o Broker recebeu o webhook |
| `agent.outbound` | `kafka.outbound-headers` | `brand` e `traceparent` |
| `agent.dlq` | `kafka.dlq-headers` | Os headers originais da ação, mais `dlq_reason`, `dlq_status` (opcional), `dlq_source_topic`, `dlq_source_partition`, `dlq_source_offset` e `dlq_failed_at` |

Na DLQ, a mensagem mantém chave, payload e headers originais, e os headers de diagnóstico dizem por que ela está ali. Na republicação pela tela `/admin/dlq`, o `Broker::DlqEndpoints` tira da mensagem os headers listados no schema `kafka.dlq-headers` antes de publicá-la de novo em `agent.outbound`:

| `dlq_reason` | Significado |
| - | - |
| `invalid_message` | Valor ilegível ou sem os campos da `Idempotency-Key`; o Core não foi chamado |
| `core_rejected` | O Core recusou a ação com status final diferente de 200 e 409 |
| `retries_exhausted` | Falha transitória na última tentativa |

`dlq_status` é o status HTTP da última resposta do Core, ausente quando o Core não foi chamado ou não respondeu.

### Horário de gravação no Kafka

A confirmação do Kafka acontece depois que a mensagem está gravada, e os headers de um registro não mudam depois da publicação. Por isso o horário de gravação não é header:

- o tópico `agent.inbound` tem `message.timestamp.type=LogAppendTime`, aplicado por `infra/redpanda/create-topics.sh` com `rpk topic alter-config`, que vale também para o tópico existente; o timestamp de cada registro é o horário em que o Redpanda grava a mensagem;
- o agente lê o timestamp do registro e o devolve na ação, em `timestamps.kafka_appended_at`.

O valor é o horário da gravação, não o da chegada da confirmação ao Broker. A medida exata da H2, do `received_at` até a confirmação no Broker, é uma métrica do Broker.

### Ação do agente

Schema `action`. É o valor da mensagem Kafka em `agent.outbound`, com chave `conversation_id`, e o corpo da chamada do Broker à API de ações, sem alteração.

| Campo | Conteúdo |
| - | - |
| `type` | `reply`, `escalate`, `categorize` ou `resolve` |
| `inbound_event_id` | `event_id` do `message.created` que originou a ação |
| `brand`, `conversation_id` | Marca e conversa |
| `based_on_sequence` | Sequência da última mensagem que o agente considerou |
| `tools` | Ferramentas consultadas: `name`, `input`, `output`, `started_at` e `finished_at`; lista vazia quando nenhuma foi consultada |
| `timestamps` | `broker_received_at` e `kafka_appended_at`, devolvidos pelo agente; `agent_consumed_at` e `agent_published_at`, do próprio agente; os quatro obrigatórios |
| `model` | Opcional: `name`, `version` e `parameters` do modelo que produziu a decisão, quando o agente o informa |
| `traceparent` | Contexto de trace W3C do agente |

| Ação | Campos próprios |
| - | - |
| `reply` | `text` |
| `escalate` | `reason`, `summary` e `context` |
| `categorize` | `category` |
| `resolve` | `reason`, opcional |

O `context` do `escalate` é o briefing do handoff, com todos os campos obrigatórios:

| Campo | Conteúdo |
| - | - |
| `intent` | Intenção identificada |
| `entities` | Entidades, por exemplo o id da transação sintética |
| `tools` | Ferramentas e retornos: `name` e `output` |
| `attempts` | Tentativas feitas, uma frase por item |
| `sentiment` | `negative`, `neutral` ou `positive` |
| `suggested_next_step` | Próximo passo sugerido |
| `confidence` | Confiança, de 0 a 1 |

### Resposta da API de ações

Schema `action-response`. É o corpo da resposta do Core ao Broker. O formato `error` é também o corpo das respostas de erro do Core ao `GET` da `context_url`.

| `status` | Código HTTP | Campos |
| - | - | - |
| `accepted` | 200 | `type`, `conversation_id`, `event_id` do `audit_event` da ação e `message_sequence` (sequência da mensagem gravada, ou nulo) |
| `stale` | 409 | `conversation_id`, `event_id` do `audit_event` da recusa, `based_on_sequence` e `last_customer_sequence` |
| `rejected` | 409 | `conversation_id`, `event_id` do `audit_event` da recusa e `state`, o estado da conversa fora de `with_ai` |
| `error` | demais 4xx | `error` (`invalid_signature`, `expired_timestamp`, `invalid_payload`, `missing_idempotency_key`, `not_found`) e `message` |

`accepted`, `stale` e `rejected` são resultado final da `Idempotency-Key`: a repetição devolve o mesmo corpo e o mesmo código. O Broker trata os dois `409` como resultado final, sem nova tentativa e sem DLQ.

### Contexto da conversa

Schema `context`. É o corpo da resposta do Core ao `GET` da `context_url`.

| Campo | Conteúdo |
| - | - |
| `conversation` | `id`, `brand`, `channel`, `state` e `last_sequence` |
| `messages` | Histórico completo, em ordem crescente de `sequence`: `sequence`, `author`, `channel`, `text` e `created_at` |
| `customer_memory` | `summary`, `updated_at` e `conversations`, ou nulo quando o lojista não tem memória |

O campo `customer_memory` é obrigatório no corpo e aceita nulo. No objeto, os três campos são obrigatórios, sem campos extras. `conversations` tem até 5 itens, da conversa resolvida mais recentemente para a mais antiga, cada um com todos os campos abaixo e sem campos extras:

| Campo | Conteúdo |
| - | - |
| `category` | Categoria da conversa (texto não vazio), ou nulo |
| `channel` | `chat`, `whatsapp` ou `email`, o canal da primeira mensagem |
| `resolved_by` | `ai` ou `analyst` |
| `resolved_at` | Horário da resolução, UTC com milissegundos |
| `handoff_reason` | Motivo do handoff mais recente (texto não vazio), ou nulo |
| `first_message` | Início da primeira mensagem do lojista, de 1 a 80 caracteres |

Os exemplos `valid/com-memoria.json` e `valid/memoria-com-duas-conversas.json` mostram a memória preenchida; `invalid/memoria-sem-conversations.json` e `invalid/memoria-com-seis-conversas.json`, as recusas. A memória é montada pelo Core (`documents/fases/13-memoria-e-contexto.md`).

### Assinatura

Todas as chamadas HTTP entre os três componentes, as chamadas do Core aos endpoints da DLQ no Broker e a entrada JSON do chat são assinadas da mesma forma.

| Item | Definição |
| - | - |
| Algoritmo | HMAC-SHA256, resultado em hexadecimal minúsculo |
| Texto assinado | `<timestamp>.<MÉTODO>.<caminho>.<corpo>` |
| `timestamp` | Horário Unix em segundos |
| `MÉTODO` | Método HTTP em maiúsculas |
| `caminho` | Caminho da requisição, com a query string |
| `corpo` | Texto bruto do corpo; vazio no `GET` |
| Headers | `X-Cloudesk-Timestamp` e `X-Cloudesk-Signature` |
| Janela | 300 segundos, para trás e para a frente |

| Chamada | Emissor | Receptor | Segredo |
| - | - | - | - |
| Webhook `message.created` | Core (`jobs-webhooks`) | Broker (`broker-web`) | `BROKER_WEBHOOK_SECRET` |
| API de ações (`POST /api/v1/agent/actions`) | Broker (`broker-consumer`) | Core (`web`) | `AGENT_ACTIONS_SECRET` |
| `GET` da `context_url` | Agente | Core (`web`) | `AGENT_CONTEXT_SECRET` |
| Endpoints da DLQ (`GET /dlq/messages`, `POST /dlq/messages/<partition>/<offset>/reprocess`) | Core (`web`, tela `/admin/dlq`) | Broker (`broker-web`) | `BROKER_DLQ_SECRET` |
| Entrada JSON do chat (`POST /channels/chat/messages`) | Simulador de canais | Core (`web`) | `CHAT_SIGNING_SECRET` |

- O receptor recusa a chamada com timestamp fora da janela (anti-replay) e a chamada cuja assinatura não confere, com comparação em tempo constante.
- Assinar o método e o caminho amarra a assinatura a um endpoint: um corpo capturado não vale em outra rota.
- O emissor assina no momento do envio, e cada nova tentativa gera timestamp e assinatura próprios.
- Dentro da janela, a repetição de uma ação é contida pela idempotência do Core.
- O segredo é argumento das funções de assinatura, e cada chamada tem o seu, em variável de ambiente do emissor e do receptor.

### `Idempotency-Key`

- Formato: `<inbound_event_id>:<type>`, por exemplo `019a8f3e-5b7a-7c21-9d43-1f2e3a4b5c6d:reply`.
- O Broker calcula a chave a partir do corpo da ação (`Contract::IdempotencyKey.for_action`) e a envia no header `Idempotency-Key`; o Core confere que a chave recebida é a derivada do corpo.
- O agente não calcula a chave: ele devolve em `inbound_event_id` o `event_id` do evento que recebeu. Um evento reentregue ao agente produz a mesma chave.
- Cada evento de entrada admite uma ação de cada tipo.

## O que o sistema garante

- Toda peça que trafega entre Core, Broker e agente tem um schema; o webhook, a ação e os headers gravados pelo Broker são validados em produção, e as demais peças são conferidas nos testes.
- Ruby e Python validam contra os mesmos schemas e exemplos e assinam com os mesmos vetores.
- Toda chamada HTTP entre os componentes é assinada, com um segredo por chamada e janela de 5 minutos.
- A mesma ação, reentregue por qualquer salto, tem sempre a mesma `Idempotency-Key`.
- Toda ação carrega os carimbos de horário de cada salto e o `traceparent`.
- Todo `escalate` aceito tem o briefing completo.
- Toda mensagem na DLQ diz de onde veio e por que está lá.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Integração com o atendente por webhooks e broker | O formato de cada mensagem, a assinatura, a chave de idempotência e as respostas | Envio do webhook (F7), API de ações (F8), Broker (F9) e agente (F10) |
| Rastreabilidade e auditoria, com linha do tempo por mensagem e `trace_id` | `traceparent` em todas as peças e os carimbos de cada salto, reunidos na ação | Gravação no `audit_event` da ação (F8) e linha do tempo na tela (F14) |
| Handoff com resumo e contexto | O briefing obrigatório do `escalate` | Gravação do handoff (F8) e painel do analista (F11) |
| Memória e contexto entre interações | O formato do contexto, com histórico e memória do lojista | Montagem do contexto (F8) e memória (F12) |
| Agente mock determinístico com ferramentas falsas | O campo `tools` da ação e o campo opcional `model` | Agente (F10) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H2 · entrada → Kafka com p95 < 300 ms | `received_at` no webhook, `broker_received_at` no header e `kafka_appended_at` pelo `LogAppendTime` marcam os pontos do trecho |
| H3 · nada perdido nem duplicado | A `Idempotency-Key` derivada do evento é o que permite ao Core descartar reentregas, e os `409` como resultado final evitam reenvios que não mudariam nada |
| H4 · ponta a ponta com p95 < 1 s, descontado o agente | Os carimbos de consumo e publicação do agente e de cada ferramenta separam o tempo do agente do tempo da plataforma |
| H1 | Não depende do contrato diretamente |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 1 · Briefing de handoff avaliado pelo analista | O schema exige no `escalate` intenção, entidades, ferramentas e retornos, tentativas, sentimento, próximo passo sugerido e confiança. Nenhum handoff chega ao analista sem esses campos |
| 4 · Modos de falha do agente mock | As respostas `stale` e `rejected` e a repetição pela `Idempotency-Key` são as respostas definidas para os modos de ação desatualizada e ação duplicada |

## Limitações

- **Uma versão.** Existe só `v1/`. Uma mudança incompatível exige uma pasta nova e a convivência das duas versões nos três componentes, e não existe negociação de versão nas chamadas.
- **Duplicação dos padrões.** Os padrões comuns se repetem em cada schema; uma mudança neles precisa ser feita em todos os arquivos.
- **Assinatura em duas linguagens.** A assinatura tem uma implementação em Ruby e três em Python: a do agente, a cópia no simulador de canais e a conferência do kit de conformidade. Os vetores comuns garantem o mesmo resultado, mas uma mudança no esquema precisa ser feita nos quatro arquivos.
- **Validação parcial em produção.** O `broker-consumer` não valida a ação, o agente não usa os schemas, e ninguém valida em produção os headers de `agent.outbound`, o `action-response` e o `context`; essas peças dependem dos testes do lado que as emite.
- **Uma ação por tipo e evento.** A chave não distingue duas ações do mesmo tipo para o mesmo evento: a segunda é tratada como repetição da primeira.
- **Relógios.** A janela de 300 s e a comparação dos carimbos dependem de os relógios dos componentes estarem alinhados; no ambiente local, todos usam o relógio da mesma máquina.
- **Segredos compartilhados.** Cada segredo é conhecido pelo emissor e pelo receptor da chamada; a troca de um segredo exige atualizar os dois lados ao mesmo tempo.
- **Imagem de produção.** O `core/Dockerfile` de produção é construído com o contexto `./core` e não copia `contracts/`; a imagem de produção precisa de um contexto adicional de build para receber a pasta. O Compose do projeto usa o `Dockerfile.dev`, com a pasta montada como volume.

## Operação

### Disponibilidade nos serviços

- Nos serviços Rails do Compose, a pasta chega pelo volume `./contracts:/contracts:ro` e pela variável `CONTRACTS_PATH`.
- O pytest lê a pasta pelo caminho do repositório, ou por `CONTRACTS_PATH` quando definida.
- O `Gemfile` fixa a `regexp_parser` abaixo da 2.13: a `json_schemer` 2.5.0 chama `Regexp::Syntax::Base.implements`, que é método privado na `regexp_parser` 2.13.

### Verificação

| Lado | Arquivo | O que comprova |
| - | - | - |
| Ruby | `core/spec/contract/schemas_spec.rb` | Cada schema é um JSON Schema 2020-12 válido; todo exemplo de `valid/` passa e todo exemplo de `invalid/` falha |
| Ruby | `core/spec/contract/signature_spec.rb` | Os vetores de assinatura; a janela de tempo; a recusa de corpo, caminho, método, timestamp ou segredo diferentes |
| Ruby | `core/spec/contract/idempotency_key_spec.rb` | Os vetores da chave; a mesma chave para o mesmo evento e tipo |
| Ruby | `core/spec/contract/message_created_spec.rb` | O evento gravado pelo serviço de comando vira um webhook que segue o schema, com a `context_url` com a marca |
| Ruby | `core/spec/modules/agents/conversation_context_spec.rb` e `core/spec/requests/api/v1/agent/contexts_spec.rb` | O contexto montado pelo Core segue o schema `context`, e as respostas de erro do contexto seguem o `action-response` |
| Ruby | `core/spec/modules/agents/action_processor_spec.rb` e `core/spec/requests/api/v1/agent/actions_spec.rb` | As respostas da API de ações seguem o schema `action-response` |
| Python | `agent_mock/tests/contract/test_contract.py` | Os mesmos schemas, exemplos e vetores de assinatura |
| Python | `channel_simulator/tests/test_signature.py` | Os vetores de assinatura na cópia do simulador |
| Python | `agent_conformance/tests/test_signature.py` | Os vetores de assinatura na conferência do kit |
| Python | `agent_conformance/tests/test_conformance.py` | A ação e os headers publicados pelo agente sob teste seguem os schemas `action` e `kafka.outbound-headers`; a reentrega gera a mesma `Idempotency-Key`; o `escalate` leva o contexto estruturado |

Os testes em Python rodam em `agent_mock/`, com `pip install -e ".[test]"` e `pytest`; o extra `test` inclui o `jsonschema`. Os vetores de `signature-vectors.json` também são conferidos por `openssl dgst -sha256 -hmac`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Núcleo transacional e auditoria (F2) | O envelope canônico do `audit_event` é a origem do corpo do webhook |
| Simulador de canais (F5) | Usa a assinatura do contrato na entrada do chat e roda os mesmos vetores |
| Saída para o Broker (F7) | Monta o corpo com `Contract::MessageCreated.build` e assina com `BROKER_WEBHOOK_SECRET` |
| API de ações e contexto (F8) | Valida a assinatura, o schema `action` e a `Idempotency-Key`, responde conforme `action-response` e monta o `context` |
| Broker (F9) | Valida o webhook e os headers, publica o corpo sem alterar, calcula a `Idempotency-Key`, chama a API de ações e grava a DLQ com os headers de diagnóstico (`documents/fases/10-broker.md`) |
| Agente mock (F10) | Lê o timestamp do registro, devolve os carimbos, assina o `GET` do contexto e publica ações no schema `action`; o kit de conformidade confere o agente contra os schemas |
| Robustez e escala (F15) | Assina com `BROKER_DLQ_SECRET` as chamadas da tela `/admin/dlq` ao Broker, que tira os headers de `kafka.dlq-headers` na republicação |

## Fontes

- `documents/arquitetura.md`, seções "Contrato com o agente", "Idempotência" e "Auditoria e rastreabilidade"
- [JSON Schema · Draft 2020-12](https://json-schema.org/draft/2020-12)
- [json_schemer](https://github.com/davishmcclurg/json_schemer)
- [jsonschema](https://python-jsonschema.readthedocs.io/)
- [Redpanda · Topic Configuration Properties](https://docs.redpanda.com/streaming/current/reference/properties/topic-properties/)
- [W3C · Trace Context](https://www.w3.org/TR/trace-context/)

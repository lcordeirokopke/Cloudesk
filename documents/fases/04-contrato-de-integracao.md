# Cloudesk · F3 · Contrato de integração

## Objetivo

A F3 fixa o que trafega entre Core, Broker e agente, para que os três sejam construídos e testados de forma independente. Ela entrega schemas versionados, exemplos, vetores de teste, o código de assinatura e de idempotência e os testes de contrato em Ruby e em Python. Nenhum serviço novo sobe nesta fase.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Local do contrato | `contracts/` na raiz do repositório, com uma pasta por versão (`v1/`) |
| Formato | JSON Schema, draft 2020-12, um arquivo por peça, sem referência entre arquivos |
| Validação | `json_schemer` no Ruby (Core e Broker) e `jsonschema` no Python (agente) |
| Testes de contrato | RSpec e pytest leem os mesmos schemas, exemplos e vetores |
| Assinatura | HMAC-SHA256 de `<timestamp>.<MÉTODO>.<caminho>.<corpo>`, em dois headers, janela de 300 s |
| `Idempotency-Key` | `<inbound_event_id>:<type>`, calculada pelo Broker |
| Leitura do contexto | O agente assina o `GET` da `context_url` com o mesmo esquema de HMAC |
| Horário de gravação no Kafka | Timestamp do registro de `agent.inbound` (`LogAppendTime`), devolvido pelo agente na ação |
| Campos | Nomes em inglês, `snake_case`; horários em ISO 8601, UTC, com milissegundos |

## Estrutura

```text
contracts/v1/
├── schemas/                          um JSON Schema por peça
│   ├── webhook.message-created.json
│   ├── kafka.inbound-headers.json
│   ├── kafka.outbound-headers.json
│   ├── action.json
│   ├── action-response.json
│   └── context.json
├── examples/<schema>/valid/*.json    exemplos que o schema aceita
├── examples/<schema>/invalid/*.json  exemplos que o schema recusa
├── signature-vectors.json            entradas e assinaturas esperadas
└── idempotency-key-vectors.json      entradas e chaves esperadas

core/lib/contract/
├── schemas.rb            carrega e valida os schemas
├── signature.rb          assina e verifica
├── idempotency_key.rb    deriva a chave
└── message_created.rb    monta o corpo do webhook a partir do envelope
core/spec/contract/       testes de contrato em Ruby

agent_mock/src/agent_mock/signature.py     assinatura em Python
agent_mock/tests/contract/test_contract.py testes de contrato em Python
```

- O código de `core/lib/contract/` não acessa o banco: o Broker o usa e não fala com o Postgres.
- A pasta `contracts/` chega aos serviços Rails pelo volume `./contracts:/contracts:ro` do Compose e pela variável `CONTRACTS_PATH`. O pytest lê a pasta pelo caminho do repositório, ou por `CONTRACTS_PATH` quando ela está definida.
- Cada schema é autossuficiente: os padrões comuns (UUID, horário, `traceparent`, marca) se repetem em `$defs` de cada arquivo. Com isso, as duas bibliotecas validam sem configuração de resolução de referências externas.
- Os formatos são conferidos por `pattern`, e não por `format`: o JSON Schema 2020-12 trata `format` como anotação por padrão, e cada biblioteca decide se a confere.

**Embasamento.**

- A arquitetura afirma que o Broker "compartilha código com o Core (schemas do contrato, assinatura HMAC)" e que o contrato e a assinatura têm uma única implementação em Ruby.
- O `compose.yaml` monta `./core` em `/rails`; a pasta da raiz precisa de volume próprio.
- O `core/Dockerfile` de produção é construído com contexto `./core` e não copia `contracts/`. A imagem de produção precisa de um contexto adicional de build para receber a pasta; o Compose do projeto usa o `Dockerfile.dev` com volume.
- O README do `json_schemer` informa que o draft 2020-12 é o padrão da gem. O `jsonschema` oferece a classe `Draft202012Validator`.
- A `json_schemer` 2.5.0 chama `Regexp::Syntax::Base.implements`, que é método privado na `regexp_parser` 2.13. O `Gemfile` fixa a `regexp_parser` abaixo da 2.13.

## Peças do contrato

### Webhook `message.created`

Schema: `webhook.message-created`. É o corpo do webhook do Core para o Broker e o valor da mensagem Kafka em `agent.inbound`: o Broker publica o corpo recebido, sem alterar. A chave da mensagem Kafka é o `conversation_id`.

| Campo | Conteúdo |
| - | - |
| `event_id` | `event_id` do `audit_event` do evento |
| `type` | `message.created` |
| `brand` | Slug da marca |
| `conversation_id` | UUID da conversa |
| `sequence` | Sequência da mensagem na conversa, a partir de 1 |
| `received_at` | Horário em que o Core recebeu a mensagem do canal |
| `message` | `author` (`customer`, `ai`, `analyst`, `system`), `channel` (`chat`, `whatsapp`, `email`) e `text` |
| `context_url` | `/api/v1/agent/conversations/<conversation_id>/context` |
| `traceparent` | Contexto de trace W3C |

O corpo é montado por `Contract::MessageCreated.build` a partir do envelope canônico da F2: o conteúdo de `payload` sobe para o nível raiz e a `context_url` é acrescentada. Um teste grava um evento pelo serviço de comando e afirma que o webhook resultante segue o schema.

### Headers das mensagens Kafka

| Tópico | Schema | Headers |
| - | - | - |
| `agent.inbound` | `kafka.inbound-headers` | `brand`, `traceparent`, `broker_received_at` |
| `agent.outbound` | `kafka.outbound-headers` | `brand`, `traceparent` |

- `broker_received_at` é o horário em que o Broker recebeu o webhook.
- Os carimbos do agente seguem no corpo da ação.

### Horário de gravação no Kafka

A confirmação do Kafka acontece depois que a mensagem está gravada, e os headers de um registro Kafka não mudam depois da publicação. Por isso o horário não é header:

- o tópico `agent.inbound` tem `message.timestamp.type=LogAppendTime`, e o timestamp de cada registro é o horário em que o Redpanda grava a mensagem;
- o agente lê o timestamp do registro e o devolve na ação, em `timestamps.kafka_appended_at`;
- o script `infra/redpanda/create-topics.sh` aplica a configuração com `rpk topic alter-config`, que vale também para o tópico existente;
- o valor é o horário da gravação, e não o da chegada da confirmação ao Broker. A medida exata da hipótese H2, do `received_at` até a confirmação no Broker, é métrica do Broker na F14.

**Embasamento.** A documentação da Redpanda lista a propriedade de tópico `message.timestamp.type`, com os valores `CreateTime` e `LogAppendTime` e padrão `CreateTime`. Com o padrão, o timestamp é o horário de criação informado pelo produtor.

### Ações do agente

Schema: `action`. É o valor da mensagem Kafka em `agent.outbound` e o corpo da chamada do Broker à API de ações do Core. A chave da mensagem Kafka é o `conversation_id`.

Campos comuns às quatro ações:

| Campo | Conteúdo |
| - | - |
| `type` | `reply`, `escalate`, `categorize` ou `resolve` |
| `inbound_event_id` | `event_id` do evento `message.created` que originou a ação |
| `brand` | Slug da marca |
| `conversation_id` | UUID da conversa |
| `based_on_sequence` | Sequência da última mensagem que o agente considerou |
| `tools` | Registro das ferramentas consultadas: `name`, `input`, `output`, `started_at`, `finished_at`; lista vazia quando nenhuma foi consultada |
| `timestamps` | `broker_received_at` e `kafka_appended_at`, devolvidos pelo agente; `agent_consumed_at` e `agent_published_at`, do próprio agente |
| `model` | Opcional; `name`, `version` e `parameters`, presente quando a decisão vem de um LLM (F16) |
| `traceparent` | Contexto de trace W3C do agente |

Campos de cada ação:

| Ação | Campos |
| - | - |
| `reply` | `text` |
| `escalate` | `reason`, `summary` e `context` |
| `categorize` | `category` |
| `resolve` | `reason`, opcional |

Contexto do `escalate`, com todos os campos obrigatórios:

| Campo | Conteúdo |
| - | - |
| `intent` | Intenção identificada |
| `entities` | Entidades, por exemplo o id da transação sintética |
| `tools` | Ferramentas e retornos: `name` e `output` |
| `attempts` | Tentativas feitas, uma frase por item |
| `sentiment` | `negative`, `neutral` ou `positive` |
| `suggested_next_step` | Próximo passo sugerido |
| `confidence` | Confiança, de 0 a 1 |

O schema recusa campo de uma ação em outra (por exemplo, `category` em um `reply`) e campo fora do contrato.

### Resposta da API de ações

Schema: `action-response`. É o corpo da resposta do Core ao Broker.

| `status` | Código HTTP | Campos |
| - | - | - |
| `accepted` | 2xx | `type`, `conversation_id`, `event_id` do `audit_event` da ação e `message_sequence` (sequência da mensagem gravada, ou nulo) |
| `stale` | 409 | `conversation_id`, `event_id` do `audit_event` da rejeição, `based_on_sequence` e `last_customer_sequence` |
| `error` | demais 4xx | `error` (`invalid_signature`, `expired_timestamp`, `invalid_payload`, `missing_idempotency_key`, `not_found`) e `message` |

A repetição de uma ação com a mesma `Idempotency-Key` devolve o corpo da primeira execução, guardado em `processed_events.result`.

### Contexto da conversa

Schema: `context`. É o corpo da resposta do Core ao `GET` da `context_url`.

| Campo | Conteúdo |
| - | - |
| `conversation` | `id`, `brand`, `channel`, `state` e `last_sequence` |
| `messages` | Histórico completo, em ordem crescente de `sequence`: `sequence`, `author`, `channel`, `text`, `created_at` |
| `customer_memory` | `summary` e `updated_at`, ou nulo quando o lojista não tem memória |

O conteúdo de `customer_memory` nasce na F12; o campo faz parte do contrato desde a F3.

## Assinatura

Todas as chamadas HTTP entre os três componentes são assinadas da mesma forma.

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

- O receptor recusa a chamada com timestamp fora da janela (anti-replay) e a chamada cuja assinatura não confere. A comparação é feita em tempo constante.
- Assinar o método e o caminho amarra a assinatura a um endpoint: um corpo capturado não vale em outra rota.
- O emissor assina no momento do envio. Um job reenviado pelo Solid Queue gera timestamp e assinatura próprios a cada tentativa.
- Dentro da janela, a repetição de uma ação é contida pela idempotência do Core.
- O segredo é argumento das funções de assinatura. As variáveis de ambiente dos segredos entram junto com cada emissor e receptor: F7 e F9 para o webhook, F8 e F9 para a API de ações, F8 e F10 para o contexto.

Chamadas assinadas:

| Chamada | Emissor | Receptor |
| - | - | - |
| Webhook `message.created` | Core (`jobs-webhooks`) | Broker (`broker-web`) |
| API de ações | Broker (`broker-consumer`) | Core (`web`) |
| `GET` da `context_url` | Agente | Core (`web`) |

**Embasamento.**

- `OpenSSL::HMAC.hexdigest` e `OpenSSL.secure_compare` fazem parte da biblioteca padrão do Ruby; `hmac` e `hashlib` fazem parte da biblioteca padrão do Python.
- Os vetores de `signature-vectors.json` são conferidos pelas duas implementações e por `openssl dgst -sha256 -hmac`.

## `Idempotency-Key`

- Formato: `<inbound_event_id>:<type>`, por exemplo `019a8f3e-5b7a-7c21-9d43-1f2e3a4b5c6d:reply`.
- O Broker calcula a chave a partir do corpo da ação (`Contract::IdempotencyKey.for_action`) e a envia no header `Idempotency-Key` à API de ações.
- O agente não calcula a chave: ele devolve em `inbound_event_id` o `event_id` do evento que recebeu. Um evento reentregue ao agente produz a mesma chave.
- Cada evento de entrada admite uma ação de cada tipo.
- A fórmula tem uma única implementação, em Ruby, usada pelo Broker.

## Testes de contrato

| Lado | Arquivo | O que afirma |
| - | - | - |
| Ruby | `core/spec/contract/schemas_spec.rb` | Cada schema é um JSON Schema 2020-12 válido; todo exemplo de `valid/` passa; todo exemplo de `invalid/` falha |
| Ruby | `core/spec/contract/signature_spec.rb` | Os vetores de assinatura; a janela de tempo; a recusa de corpo, caminho, método, timestamp ou segredo diferentes |
| Ruby | `core/spec/contract/idempotency_key_spec.rb` | Os vetores da chave; a mesma chave para o mesmo evento e tipo |
| Ruby | `core/spec/contract/message_created_spec.rb` | O evento gravado pelo serviço de comando vira um webhook que segue o schema |
| Python | `agent_mock/tests/contract/test_contract.py` | Os mesmos schemas, exemplos e vetores de assinatura |

Os testes em Python rodam com `pip install -e ".[test]"` e `pytest`, em `agent_mock/`. O extra `test` do `pyproject.toml` inclui o `jsonschema`.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`: os schemas estão no repositório e os testes de contrato dos dois lados passam com os mesmos exemplos.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F5 | O simulador de canais usa do contrato só a assinatura, na entrada JSON do chat | `channel_simulator/signature.py` é cópia de `agent_mock/signature.py`, testada com `contracts/v1/signature-vectors.json`; detalhes em `documents/fases/06-simulador-de-canais.md` |
| F7 | O corpo do webhook vem de `Contract::MessageCreated.build` e os headers de `Contract::Signature.headers` | O job assina e envia; o caminho do endpoint do Broker é definido na F9 |
| F8 | A API valida a assinatura, o schema `action` e a `Idempotency-Key`, e responde conforme `action-response` | Os caminhos dos endpoints de ação são definidos na F8; o endpoint de contexto valida a assinatura do agente |
| F9 | O Broker calcula a `Idempotency-Key`, grava `broker_received_at` no header e publica o corpo do webhook sem alterar | O `broker-web` e o `broker-consumer` usam `core/lib/contract/` |
| F10 | O agente lê o timestamp do registro, devolve os carimbos e assina o `GET` do contexto | O agente usa `agent_mock/signature.py`; o segredo do agente é ponto em aberto, decidido antes da F8 |
| F16 | O modo LLM usa o campo `model` da ação | O contrato não muda |

## Fontes

- [JSON Schema - Draft 2020-12](https://json-schema.org/draft/2020-12)
- [json_schemer](https://github.com/davishmcclurg/json_schemer)
- [jsonschema](https://python-jsonschema.readthedocs.io/)
- [Redpanda - Topic Configuration Properties](https://docs.redpanda.com/streaming/current/reference/properties/topic-properties/)
- [W3C - Trace Context](https://www.w3.org/TR/trace-context/)

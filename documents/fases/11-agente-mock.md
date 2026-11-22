# Cloudesk · Agente mock

## O que é

O agente mock é o atendente de IA simulado do Cloudesk. É um processo Python (`agent-mock`) que consome os eventos `message.created` em `agent.inbound`, lê o contexto da conversa no Core, decide de forma determinística o que fazer e publica uma ação em `agent.outbound`, que o Broker leva à API de ações do Core.

O agente não guarda estado nem acessa o banco. Ele fala com o Kafka e, por HTTP assinado, só com a `context_url` do Core. O código fica em `agent_mock/src/agent_mock/`, e os testes em `agent_mock/tests/`.

## Onde fica no fluxo

```text
broker-web → agent.inbound → agente mock → agent.outbound → broker-consumer → API de ações do Core
                                  │
                                  └→ GET {CORE_URL}{context_url} (assinado com AGENT_CONTEXT_SECRET)
```

O agente fecha o caminho de volta: canal → Core → webhook → Broker → `agent.inbound` → agente mock → `agent.outbound` → Broker → API de ações → canal.

## Por que existe e que valor gera

**Caminho ponta a ponta exercitado.** O agente atende como um usuário da plataforma, pelo mesmo contrato que um agente real usaria: consome o evento, lê o contexto, decide e publica uma ação. Com ele, a integração inteira roda sem o agente real e sem sistemas de produção.

**Determinismo.** A mesma mensagem gera sempre a mesma ação, com o mesmo texto e as mesmas ferramentas, em qualquer conversa. Isso torna reproduzíveis os testes, o experimento e a conferência de duplicidade: um evento reentregue gera a mesma `Idempotency-Key`, e o Core deduplica.

**Ordem decidida pelo contexto.** Antes de decidir, o agente lê o histórico no Core e descarta o evento que já foi superado por uma mensagem mais nova do lojista. A ordem não depende do transporte.

**Carga controlável.** A latência artificial fixa e a concorrência configurável permitem medir a plataforma com um agente de comportamento conhecido, descontando o tempo do agente da latência ponta a ponta.

## Como funciona

### Um evento, do consumo à publicação

`Processor.handle` (`processor.py`) trata cada registro de `agent.inbound`:

1. **Consumo.** Carimba `agent_consumed_at` e lê o registro (`events.py`): o valor é o JSON do `message.created`; os headers `brand`, `traceparent` e `broker_received_at` vêm do Broker; o timestamp do registro (o tópico usa `LogAppendTime`) vira `kafka_appended_at`; o `received_at` do corpo é a referência da janela da memória do lojista.
2. **Marca.** O locale da marca vem de `AGENT_BRAND_LOCALES`.
3. **Contexto.** `GET {CORE_URL}{context_url}`, assinado com `AGENT_CONTEXT_SECRET`, com o `traceparent` do salto do agente (`context_client.py`).
4. **Descarte por mensagem mais nova.** Mensagem do lojista no contexto com `sequence` maior que a do evento.
5. **Descarte por estado.** Conversa fora de `with_ai`.
6. **Decisão.** Sobre o texto da mensagem com a `sequence` do evento no contexto, ou o texto do evento quando ela não aparece, sem os marcadores de falha (`failure.marker`), e sobre a memória do lojista no contexto, com a janela `AGENT_MEMORY_WINDOW_DAYS` (`decision.py`, `memory.py`).
7. **Latência artificial.** Espera `AGENT_LATENCY_MS`, depois das ferramentas e antes da publicação.
8. **Publicação.** Carimba `agent_published_at` e publica no tópico de saída (`AGENT_OUTBOUND_TOPIC`, `agent.outbound` por padrão) com a chave `conversation_id` e os headers `brand` e `traceparent`, aguardando a confirmação do Kafka.

O modo de falha age entre a decisão e a publicação, só nos eventos afetados, e vem de duas fontes (`failure.py`):

- **Marcador no texto.** `[falha:drop]`, `[falha:duplicate]`, `[falha:stale]`, `[falha:delay]` e `[falha:delay=<ms>]`, em minúsculas, em qualquer ponto do texto decidido. O evento com marcador é sempre afetado pelo modo do marcador, sem consultar `AGENT_FAILURE_MODE` nem `AGENT_FAILURE_RATE`; com mais de um marcador, vale o primeiro. `delay` sem valor usa `AGENT_FAILURE_DELAY_MS`. Todos os marcadores válidos saem do texto antes da intenção, das entidades e do sentimento, com os espaços repetidos reduzidos a um e as pontas aparadas, então a ação é a mesma do texto sem marcador. `=<ms>` só vale com `delay`: `[falha:drop=10]`, `[FALHA:drop]` e outros textos entre colchetes não são marcador e ficam no texto. O Core grava a mensagem com o marcador; os marcadores não são palavras do classificador do Core e não mudam a categoria. O marcador escolhe uma conversa da demonstração sem mudar a configuração do agente; os cenários `failure-*` do simulador o usam.
- **Configuração.** Sem marcador, `AGENT_FAILURE_MODE`, só no evento escolhido pelo `event_id`: os primeiros 8 dígitos hexadecimais do SHA-256 do `event_id`, divididos por `2^32`, menores que `AGENT_FAILURE_RATE`. Com a taxa padrão 1, todo evento é afetado; o mesmo evento reentregue tem sempre a mesma escolha. Modo fora da lista, taxa fora de 0 a 1 ou atraso negativo é erro de configuração (`config.py`).

O log do evento afetado leva `failure` (o modo) e `failure_source` (`marker` ou `config`).

| Modo | Efeito no evento afetado | O que a plataforma faz |
| - | - | - |
| `none` | Nenhum (padrão) | |
| `delay` | Soma à latência antes da publicação o valor de `[falha:delay=<ms>]` ou, sem ele, `AGENT_FAILURE_DELAY_MS` | A resposta chega atrasada; passando da metade do SLA, a varredura do timeout envia a mensagem de espera |
| `drop` | Termina sem publicar; o offset é confirmado | A varredura do timeout envia a mensagem de espera e depois escala |
| `duplicate` | Publica a mesma ação duas vezes, cada uma aguardando a confirmação do Kafka | O Core aplica a primeira e devolve `200` com o mesmo corpo na segunda, sem novo efeito |
| `stale` | Publica a ação com `based_on_sequence` igual à `sequence` do evento menos 1; com `sequence` 1, publica sem alteração | O Core responde `409 stale` e grava `agent.action.stale`; o lojista fica coberto pela varredura do timeout |

Cada evento gera uma linha de log JSON no stdout (`logs.py`), com `event_id`, `conversation_id`, `brand`, `sequence`, partição, offset e o resultado:

| `result` | Situação | Publica |
| - | - | - |
| `published` | Ação publicada e confirmada pelo Kafka | sim |
| `discarded_newer` | O contexto tem mensagem do lojista mais nova que o evento | não |
| `discarded_state` | A conversa não está em `with_ai` | não |
| `context_error` | O Core recusou o `GET` do contexto com erro permanente | não |
| `invalid_event` | Registro sem os campos ou headers do contrato, inclusive sem `received_at` válido | não |
| `unknown_brand` | Marca sem locale em `AGENT_BRAND_LOCALES` | não |
| `failure_drop` | Modo `drop`: o evento afetado termina sem publicação | não |
| `failure_stale_skipped` | Modo `stale` com `sequence` 1: a ação é publicada sem alteração | sim |

No modo de falha, a linha `published` do evento afetado leva o campo `failure` com o modo.

Todo resultado é final para o registro: o offset é confirmado depois dele.

### Leitura do contexto

| Resposta | Classificação | Tratamento |
| - | - | - |
| `200` com `conversation` e `messages` | ok | segue para a decisão |
| `401`, `404`, `422` e demais `4xx` | permanente | `context_error`, sem publicar |
| `200` com corpo fora do formato, `3xx` | permanente | `context_error`, sem publicar |
| Erro de rede, timeout, `408`, `429`, `5xx` | transitória | nova tentativa |

A nova tentativa espera 2 s, dobra a cada vez e para de crescer em 60 s, sem limite de tentativas; cada uma gera um log `contexto indisponível; nova tentativa`. O registro não é concluído enquanto o contexto não responde, então o offset fica parado. Cada `GET` tem timeout de `AGENT_CONTEXT_TIMEOUT_SECONDS`.

A assinatura segue o contrato: texto `<timestamp>.GET.<context_url>.` (corpo vazio), headers `X-Cloudesk-Timestamp` e `X-Cloudesk-Signature` (`signature.py`). A `context_url` traz o slug da marca no caminho e entra inteira na assinatura.

### Intenção

`intents.py` tem uma tabela de palavras-chave por locale (`pt-BR` e `en-US`) para seis intenções, na ordem: `agradecimento`, `transacao`, `repasse`, `taxas`, `maquininha` e `saudacao`.

- O texto é normalizado: caixa baixa, sem acentos, dividido em palavras.
- Cada expressão casa só com palavras inteiras.
- Em cada trecho do texto conta só a expressão mais longa que começa ali, e cada casamento soma 1 ponto.
- Vence a maior pontuação; o empate fica com a intenção que vem primeiro na ordem.
- Sem casamento, a intenção é `desconhecida`.

Expressões compostas resolvem as frases do simulador que misturam assuntos: "cobrado duas vezes" e "charged twice" contam para `transacao`, e "cobrado" ou "charged" sozinhos não contam, então "Fui cobrado R$ 10,00 de taxa" cai em `taxas`. O corpus `agent_mock/tests/fixtures/intent_corpus.json` traz os modelos de texto do simulador nos dois locales, frases de agradecimento e frases sem intenção.

### Entidades

`entities.py` extrai, por expressão regular, a primeira ocorrência de cada entidade:

| Chave | No texto | Valor |
| - | - | - |
| `id_transacao` | `TX` seguido de 10 dígitos | o id em maiúsculas |
| `numero_serie` | `SN` seguido de 8 dígitos | o número em maiúsculas |
| `data` | `dd/mm/aaaa` em pt-BR, `mm/dd/yyyy` em en-US | data ISO; data inexistente é ignorada |
| `valor` | `R$ 1.532,40` em pt-BR, `$1,532.40` em en-US | decimal com ponto |

### Ferramentas falsas

`tools.py` tem as quatro ferramentas como funções puras, sem banco. O retorno vem do SHA-256 da entrada canônica (JSON com chaves ordenadas, com o nome da ferramenta). A entrada não leva ids de conversa nem de contato, então a mesma mensagem gera o mesmo retorno em qualquer conversa. Entrada e saída usam chaves em português.

| Ferramenta | Entrada | Retorno |
| - | - | - |
| `consultar_transacao` | `id_transacao` | `aprovada` 60%, `estornada` 15%, `contestada` 15%, `nao_encontrada` 10%; com `valor` e `data`, menos em `nao_encontrada` |
| `consultar_repasse` | `data`, quando a mensagem traz uma; senão, entrada vazia | `pago` 50% (`valor`, `data_pagamento`), `agendado` 30% (`valor`, `previsao`), `nao_encontrado` 20% |
| `consultar_taxas` | `marca` | tabela fixa por marca: `debito`, `credito_a_vista`, `credito_12x`, `pix`, em percentual |
| `status_maquininha` | `numero_serie` | `online` 50%, `offline` 30%, `defeito` 20% |

Os percentuais são as faixas do primeiro bloco do hash; valores e datas sintéticos saem de outros blocos, com as datas contadas a partir de uma data de referência fixa. Cada chamada entra em `tools` da ação com `name`, `input`, `output`, `started_at` e `finished_at`.

### Tabela de decisão

| Intenção | Ferramenta | Resultado | Ação |
| - | - | - | - |
| `agradecimento` | nenhuma | | `resolve`, motivo `lojista_confirmou` |
| `saudacao` | nenhuma | | `reply` de boas-vindas pedindo o assunto |
| `transacao` sem `TX` | nenhuma | | `reply` pedindo o id da transação |
| `transacao` com `TX` | `consultar_transacao` | `aprovada`, `estornada` | `reply` com status, valor e data |
| | | `contestada` | `escalate`, motivo `transacao_contestada` |
| | | `nao_encontrada` | `escalate`, motivo `transacao_nao_localizada` |
| `repasse` | `consultar_repasse` | `pago`, `agendado` | `reply` com valor e data |
| | | `nao_encontrado` | `escalate`, motivo `repasse_nao_localizado` |
| `taxas` | `consultar_taxas` | tabela da marca | `reply` com as taxas |
| `maquininha` sem `SN` | nenhuma | | `reply` pedindo o número de série |
| `maquininha` com `SN` | `status_maquininha` | `online`, `offline` | `reply` com passos de reinício ou de conexão |
| | | `defeito` | `escalate`, motivo `maquininha_com_defeito` |
| `desconhecida` | nenhuma | | `escalate`, motivo `intencao_nao_identificada` |

Os textos ao lojista seguem o locale da marca, com valor e data no formato do locale. O `escalate` leva `reason`, `summary` e `context` completo: `intent`, `entities`, `tools` (`name` e `output` de cada chamada), `attempts` (uma linha por ferramenta, com entrada e status, e por último a explicação da confiança), `sentiment`, `suggested_next_step`, fixo por motivo, e `confidence`, calculada por regra:

| Motivo | Base da confiança | Próximo passo sugerido |
| - | - | - |
| `transacao_contestada` | 0,8 | Abrir a contestação da transação e informar o prazo ao lojista |
| `transacao_nao_localizada` | 0,5 | Localizar a transação no sistema de pagamentos e confirmar com o lojista |
| `repasse_nao_localizado` | 0,5 | Verificar o repasse no sistema financeiro e informar o prazo ao lojista |
| `maquininha_com_defeito` | 0,8 | Enviar uma maquininha de troca ao lojista |
| `intencao_nao_identificada` | 0,2 | Ler a mensagem e identificar a necessidade do lojista |

Da base saem dois ajustes: menos 0,15 quando a intenção é `repasse` e falta a `data` que `consultar_repasse` aceitaria, e menos 0,1 quando a memória do lojista tem conversa do mesmo assunto na janela (`memory.previous`, problema recorrente). O resultado fica entre 0,05 e 0,95, com 2 casas. A última linha de `attempts` explica o cálculo, com vírgula decimal e a data UTC da conversa da memória, por exemplo `Confiança 0,4: base 0,5 por repasse_nao_localizado; -0,1 conversa do mesmo assunto em 03/11/2026` ou, sem ajuste, `Confiança 0,8: base 0,8 por transacao_contestada`. Valores possíveis: `transacao_contestada` e `maquininha_com_defeito` 0,8 ou 0,7; `transacao_nao_localizada` 0,5 ou 0,4; `repasse_nao_localizado` 0,5 ou 0,4; `intencao_nao_identificada` 0,2 (a intenção `desconhecida` não tem assunto na memória). Com as ferramentas falsas, `consultar_repasse` sem data recebe sempre a mesma entrada e devolve `pago`, então o repasse sem data nunca escala no mock; o ajuste da data (0,35 e 0,25) vale pela regra e é testado direto na decisão. O contrato não muda: a explicação fica em `attempts`.

O `sentiment` é `negative` quando o texto tem uma expressão da lista negativa do locale ("absurdo", "duas vezes", "ainda não", "não caiu", "twice", "missing", "not arrived" e outras); senão, `neutral`. Resumo, tentativas, explicação da confiança e próximo passo são para o analista e ficam em português, nos dois locales.

### Memória do lojista

Quando `customer_memory.conversations` tem conversa com categoria equivalente à intenção atual e `resolved_at` entre o `received_at` do evento menos `AGENT_MEMORY_WINDOW_DAYS` dias e o `received_at` (`memory.py`), todo `reply` das intenções `transacao`, `repasse`, `taxas` e `maquininha` começa com um prefixo no locale da marca, com o assunto e a data UTC da conversa mais recente: `Vi que você já falou com a gente sobre {assunto} em {data}. ` ou `I see you contacted us about {assunto} on {data}. `. `saudacao`, `resolve` e `escalate` não mudam. A equivalência das categorias, os assuntos e a montagem da memória no Core estão em `documents/fases/13-memoria-e-contexto.md`.

### A ação publicada

`action.py` monta o valor do schema `action`:

| Campo | Origem |
| - | - |
| `inbound_event_id` | `event_id` do evento |
| `brand`, `conversation_id` | do evento |
| `based_on_sequence` | `sequence` do evento |
| `tools` | registro das chamadas, na ordem |
| `timestamps.broker_received_at` | header do registro |
| `timestamps.kafka_appended_at` | timestamp do registro |
| `timestamps.agent_consumed_at`, `agent_published_at` | carimbos do agente |
| `traceparent` | mesmo `trace_id` do header Kafka, `parent_id` do agente (`trace.py`) |
| `text`, `reason`, `summary`, `context` | campos do tipo da ação |

Os horários seguem o formato do contrato, `YYYY-MM-DDTHH:MM:SS.mmmZ` em UTC (`clock.py`). O header `traceparent` inválido ou ausente, inclusive com ids zerados, inicia um trace, pela mesma regra de `core/lib/trace_context.rb`. O mesmo `traceparent` vai no `GET` do contexto e na ação.

### Concorrência e offsets

`runner.py` usa um `AIOKafkaConsumer` no grupo `AGENT_GROUP_ID` (`enable_auto_commit=False`, `auto_offset_reset="earliest"`) e um `AIOKafkaProducer` com `acks="all"` e `enable_idempotence=True`.

- **Por conversa.** Cada registro vira uma tarefa encadeada à anterior da mesma chave (`conversation_id`): em série dentro da conversa, em paralelo entre conversas.
- **Limite.** Um semáforo de `AGENT_CONCURRENCY` limita as tarefas em andamento e segura a leitura quando cheio.
- **Offsets.** `OffsetTracker` guarda, por partição, os offsets lidos e os concluídos. O offset confirmado é o do primeiro registro lido e não concluído, ou o último concluído + 1: um registro em andamento segura a confirmação dos seguintes, mesmo concluídos.
- **Confirmação.** A cada segundo, na parada e no `on_partitions_revoked`, que espera as tarefas das partições revogadas antes de confirmar. Registros de partição revogada que ainda não foram agendados não são processados; quem fica com a partição os lê de novo.
- **Publicação sem confirmação.** Falha do produtor repete com 2 s, exponencial, até 60 s, com novo `agent_published_at` a cada tentativa; o offset só avança depois da confirmação.
- **Parada.** SIGTERM e SIGINT param a leitura, esperam os eventos em andamento por até 5 s, cancelam o restante e confirmam os offsets concluídos.
- **Falha inesperada.** Exceção fora dos casos acima é registrada com nível `error`, o offset do registro não avança e o processo para com código 1.

Na queda do processo, os registros sem offset confirmado são relidos; a ação republicada tem a mesma `Idempotency-Key` e o Core devolve o resultado guardado.

## O que o sistema garante

- Com `AGENT_FAILURE_MODE=none`, uma ação por evento, com `based_on_sequence` igual à `sequence` do evento, chave `conversation_id` e os headers do schema `kafka.outbound-headers`. Os modos de falha mudam isso só nos eventos afetados, pela configuração ou pelo marcador no texto: nenhuma ação (`drop`), a mesma ação duas vezes (`duplicate`) ou `based_on_sequence` menos 1 (`stale`).
- A mesma entrada gera a mesma ação, fora carimbos de horário e `traceparent`: a decisão depende do texto, da marca e do locale e, no prefixo do `reply`, da memória do contexto e do `received_at` do evento, nunca do relógio do processo; a mesma mensagem em conversas diferentes, com a mesma memória, gera o mesmo tipo, texto e ferramentas.
- Um evento reentregue gera ação com o mesmo `inbound_event_id` e o mesmo `type`, portanto a mesma `Idempotency-Key`.
- O evento mais antigo que o contexto (`discarded_newer`) e o de conversa fora de `with_ai` (`discarded_state`) não geram ação.
- O offset de um evento só é confirmado depois da confirmação do Kafka na publicação ou de um descarte.
- Os eventos de uma conversa são decididos na ordem do tópico.
- O `traceparent` mantém o `trace_id` do evento.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Agente mock determinístico com ferramentas falsas | Intenção por palavras-chave, quatro ferramentas por hash, tabela de decisão, confiança por regra, latência artificial e modos de falha por configuração e por marcador | Avaliação das melhorias, kit de conformidade e cenários de demonstração em `documents/fases/17-avaliacao-de-melhorias-do-agente-mock.md` |
| Integração com o atendente por webhooks e broker | Consumo de `agent.inbound`, leitura do contexto e publicação em `agent.outbound` | Webhook (F7), API de ações e contexto (F8), Broker (F9) |
| Handoff com resumo e contexto | `escalate` com motivo, resumo e contexto estruturado | Fila humana, painel e briefing (F11) |
| Rastreabilidade | `traceparent` continuado e os quatro carimbos da ação | Gravação no `audit_event` (F8) e linha do tempo (F14) |
| Multi-marca | Locale e taxas por marca | RLS e marca no corpo da ação (F1, F8) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s sem backlog crescente | `AGENT_CONCURRENCY` por processo e consumo paralelo entre conversas; o lag do grupo `cloudesk-agent` é uma das medidas de backlog |
| H3 · nenhuma perda nem duplicação | Offset confirmado só depois da publicação; a reentrega gera a mesma `Idempotency-Key` |
| H4 · latência ponta a ponta descontada a do agente | Latência artificial fixa (`AGENT_LATENCY_MS`) e os carimbos `agent_consumed_at` e `agent_published_at` |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 1 · Briefing de handoff | O `escalate` leva resumo, tentativas, sentimento, próximo passo e confiança por regra, com a explicação do cálculo na última tentativa |
| 4 · Modos de falha do agente mock | Atraso, sem resposta, ação duplicada e ação desatualizada, por `AGENT_FAILURE_MODE`, com a fração dos eventos afetados em `AGENT_FAILURE_RATE`, ou por marcador `[falha:<modo>]` no texto de uma conversa. A duplicada produz um único efeito no Core, a desatualizada recebe `409 stale` e a falta de resposta é tratada pela varredura do timeout (F11) |

## Limitações

- **Classificação por palavras-chave.** Frases fora do vocabulário da tabela caem em `desconhecida` e escalam; frases com vários assuntos ficam com a maior pontuação ou com a ordem da lista.
- **Uma mensagem por decisão.** A decisão usa só o texto da mensagem do evento; o histórico do contexto serve para os descartes, não para a decisão. Uma resposta do lojista com só o id da transação ou o número de série, sem palavra-chave, cai em `desconhecida` e escala.
- **Repetição sem limite.** Com o Core fora do ar, o evento espera o contexto indefinidamente: a conversa fica parada, a confirmação da partição também, e a revogação da partição espera a tarefa. Se a leitura fica segura pelo semáforo além do `max_poll_interval_ms` do aiokafka (300 s por padrão), o consumidor sai do grupo e as partições vão para outro membro.
- **Parada com falha.** Uma falha inesperada para o processo; o serviço `agent-mock` do Compose não tem política de reinício.
- **Textos do analista em português.** Resumo, tentativas e próximo passo do `escalate` não seguem o locale da marca.
- **Ferramentas sem estado.** O retorno não muda com o tempo nem com ações anteriores; consultar o mesmo `TX` dá sempre o mesmo status.

## Operação

### Processos

| Serviço | Comando | Grupo |
| - | - | - |
| `agent-mock` | `agent-mock run` | `cloudesk-agent` em `agent.inbound` |

O serviço sobe depois do `redpanda-init` e do `web`. A imagem `cloudesk-agent-mock:dev` instala o pacote em modo editável, com a pasta `agent_mock/` montada em `/app`.

### Configuração

| Variável | Uso | Padrão |
| - | - | - |
| `KAFKA_BROKERS` | Endereço do Kafka | `redpanda:9092` |
| `CORE_URL` | Base da `context_url` | `http://web:3000` |
| `AGENT_CONTEXT_SECRET` | Assinatura do `GET` do contexto, a mesma do Core | `.env` |
| `AGENT_GROUP_ID` | Grupo de consumo | `cloudesk-agent` |
| `AGENT_INBOUND_TOPIC` | Tópico de entrada; vazio é erro de configuração | `agent.inbound` |
| `AGENT_OUTBOUND_TOPIC` | Tópico de saída; vazio é erro de configuração | `agent.outbound` |
| `AGENT_CONCURRENCY` | Eventos em andamento por processo | `100` |
| `AGENT_LATENCY_MS` | Latência artificial antes da publicação | `0` |
| `AGENT_CONTEXT_TIMEOUT_SECONDS` | Timeout de cada `GET` do contexto | `5` |
| `AGENT_BRAND_LOCALES` | Locale de cada marca | `infinitepay:pt-BR,jim:en-US` |
| `AGENT_FAILURE_MODE` | Modo de falha: `none`, `delay`, `drop`, `duplicate` ou `stale`; outro valor é erro de configuração | `none` |
| `AGENT_FAILURE_RATE` | Fração dos eventos afetados, de 0 a 1 | `1` |
| `AGENT_FAILURE_DELAY_MS` | Atraso somado à latência no modo `delay` | `0` |
| `AGENT_MEMORY_WINDOW_DAYS` | Dias antes do `received_at` do evento em que uma conversa da memória entra no prefixo do `reply` e reduz a confiança do `escalate`; inteiro maior ou igual a zero | `30` |
| `CONTRACTS_PATH` | Pasta do contrato, para os testes | `/contracts` |

`AGENT_LATENCY_MS`, `AGENT_CONCURRENCY`, `AGENT_MEMORY_WINDOW_DAYS` e as três variáveis `AGENT_FAILURE_*` podem ser trocados no `.env` ou na linha de comando (`AGENT_FAILURE_MODE=drop docker compose up -d agent-mock`). O `compose.yaml` não passa `AGENT_INBOUND_TOPIC` nem `AGENT_OUTBOUND_TOPIC` ao `agent-mock`; o `agent-mock-conformance`, do profile `conformance`, usa `conformance.inbound` e `conformance.outbound`.

Dependências fixadas no `agent_mock/pyproject.toml`, com Python 3.13: `aiokafka` 0.15.0 e `aiohttp` 3.14.5; nos testes, `pytest` 9.2.0, `pytest-asyncio` 1.5.0 e `jsonschema` 4.26.0.

### Inspeção

```text
docker compose logs -f agent-mock
docker compose exec redpanda rpk group describe cloudesk-agent
docker compose exec redpanda rpk topic consume agent.outbound -o :end -f '%p %o %k %h{%k=%v; }\n%v\n'
```

### Verificação

```text
docker compose run --rm agent-mock pytest
```

| Arquivo | O que comprova |
| - | - |
| `tests/test_intents.py` | Cada texto do corpus cai na intenção esperada; caixa, acentos, palavra inteira, expressão mais longa e empate |
| `tests/test_entities.py` | `TX`, `SN`, datas nos dois formatos, valores, tamanhos errados e ausência de entidade |
| `tests/test_tools.py` | Mesma entrada, mesmo retorno; proporções dos status em amostras fixas; taxas por marca; registro da chamada |
| `tests/test_decision.py` | Cada linha da tabela de decisão; texto decidido pelo contexto e texto informado a `decide`; prefixo da memória nas quatro intenções e nos dois locales, e sem prefixo fora da janela, sem relação ou em `saudacao`, `resolve` e `escalate`; confiança de cada motivo sem ajuste, com memória do mesmo assunto na janela, sem ajuste fora da janela ou de outro assunto, repasse sem data e os dois ajustes juntos (pela decisão direta), limites de 0,05 e 0,95; explicação como última linha de `attempts`, em português nos dois locales; mesma entrada, mesma ação |
| `tests/test_memory.py` | Equivalência das categorias das duas marcas; janela pelo `received_at` nos limites; conversa mais recente; memória nula |
| `tests/test_action.py` | Toda ação gerada pela tabela, nos dois locales, passa no schema `action`, inclusive o `escalate` com a confiança por regra e com o ajuste da memória; headers no schema `kafka.outbound-headers`; `Idempotency-Key` pelos vetores do contrato |
| `tests/test_processor.py` | Publicação com chave, headers e carimbos; descartes por mensagem mais nova, estado, erro permanente, registro inválido, evento sem `received_at` válido e marca sem locale; janela da memória repassada à decisão; repetição do transitório e da publicação; latência; reentrega e conversas diferentes com a mesma ação; cada modo de falha (atraso somado, descarte sem publicação, duas publicações iguais, `based_on_sequence` menos 1 e o caso `sequence` 1), evento fora da taxa e `none` sem efeito; marcador acima de `AGENT_FAILURE_MODE=none`, de `AGENT_FAILURE_RATE=0` e de outro modo da configuração, `delay=<ms>` e `delay` sem valor, `stale` por marcador com `sequence` 1, marcador lido no texto do contexto, decisão igual à do texto sem marcador e `failure_source` no log |
| `tests/test_failure.py` | Escolha pelo SHA-256 do `event_id`, determinística, com taxas 0 e 1 e proporção numa amostra fixa; marcador de cada modo, `delay` com e sem valor, `=<ms>` fora do `delay`, maiúsculas e outros colchetes que ficam no texto, dois marcadores, espaços reduzidos e texto sem marcador sem mudança |
| `tests/test_config.py` | Leitura e validação de `AGENT_FAILURE_MODE`, `AGENT_FAILURE_RATE`, `AGENT_FAILURE_DELAY_MS`, `AGENT_MEMORY_WINDOW_DAYS`, `AGENT_INBOUND_TOPIC` e `AGENT_OUTBOUND_TOPIC` (padrão, valor lido e vazio recusado) |
| `tests/test_context_client.py` | Servidor aiohttp de teste conferindo assinatura, caminho com a marca e `traceparent`; classificação de permanentes e transitórios; pausas de 2 a 60 s |
| `tests/test_offsets.py` | Confirmação só do offset contíguo; lacuna segura a confirmação; série por conversa e paralelo entre conversas; semáforo; falha inesperada; configuração; assinatura e publicação nos tópicos de `Settings` |
| `tests/test_trace.py` | Continuação do `traceparent` e início de trace com header inválido |
| `tests/contract/test_contract.py` | Schemas, exemplos e vetores de assinatura do contrato |

No Compose:

- `docker compose up -d --build agent-mock` sobe o serviço, e os logs saem em JSON, uma linha por evento;
- uma mensagem do simulador em cada canal (`channel-simulator send --channel whatsapp|chat|email --brand infinitepay --contacts new`) gera ação em `agent.outbound`, `audit_event` `agent.reply` com os quatro carimbos e a resposta em `channel_simulator/data/received.jsonl`, com o mesmo `trace_id` da entrada;
- com o agente parado e `rpk group seek cloudesk-agent --to start --topics agent.inbound`, o agente relê o tópico ao religar: as ações republicadas recebem do Core o resultado guardado, sem novo `audit_event` nem nova linha em `processed_events`, e os eventos de conversas já escaladas são descartados por estado;
- a mesma mensagem enviada por dois lojistas novos gera, nas duas conversas, ação com o mesmo tipo, texto e ferramentas, e o Core grava `agent.escalate` e o `Handoff` nas duas;
- com `AGENT_FAILURE_MODE=duplicate`, a API de ações recebe duas chamadas com `200` e o Core grava um único `agent.reply`, uma mensagem e uma entrega; com `stale`, a segunda mensagem do lojista recebe `409` e `agent.action.stale`, e a varredura do timeout envia a espera e escala; com `delay` e `AGENT_FAILURE_DELAY_MS=3000`, `agent_published_at` fica cerca de 3,6 s depois de `agent_consumed_at`; com `drop`, o log mostra `failure_drop` e nenhuma ação é publicada;
- no ambiente de desenvolvimento do Compose, cada requisição ao `web` leva de 0,6 a 1,1 s, inclusive `GET /up`, enquanto o Rails registra cerca de 25 ms no controller; esse tempo aparece entre `agent_consumed_at` e `agent_published_at`, porque o `GET` do contexto fica nesse intervalo.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Contrato (F3) | Schemas `webhook.message-created`, `context`, `action`, `kafka.inbound-headers` e `kafka.outbound-headers`, assinatura e vetores de `Idempotency-Key` |
| Simulador de canais (F5) | Os modelos de texto do simulador formam o corpus de intenções |
| API de ações e contexto (F8) | O Core responde o `GET` da `context_url` e processa a ação, com `409 stale` e `409 rejected` como barreira final |
| Broker (F9) | Publica o evento em `agent.inbound` com os headers e consome `agent.outbound`, derivando a `Idempotency-Key` |
| Handoff e timeout do agente (F11) | O `escalate` abre o handoff e leva a conversa à fila de escalação; o evento sem resposta da IA é coberto pela varredura do timeout, que os modos `delay`, `drop` e `stale` exercitam |
| Observabilidade (F14) | Lag do grupo `cloudesk-agent` e os carimbos do agente na linha do tempo |

## Fontes

- `documents/arquitetura.md`, seções "Contrato com o agente", "Ordem das mensagens", "Idempotência", "Ação sobre contexto desatualizado" e "Componentes simulados"
- `documents/fases/04-contrato-de-integracao.md`, seções "Headers das mensagens Kafka", "Horário de gravação no Kafka", "Assinatura" e "`Idempotency-Key`"
- `documents/fases/09-api-de-acoes-e-contexto.md`
- `documents/fases/10-broker.md`
- [PyPI · aiokafka](https://pypi.org/project/aiokafka/)
- [PyPI · aiohttp](https://pypi.org/project/aiohttp/)
- [PyPI · pytest-asyncio](https://pypi.org/project/pytest-asyncio/)
- [W3C · Trace Context](https://www.w3.org/TR/trace-context/)

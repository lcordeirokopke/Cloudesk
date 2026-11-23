# Cloudesk · Avaliação de melhorias do agente mock

## O que é

Aqui avaliamos, item a item, as melhorias possíveis do agente mock pelos critérios do TAPI (robustez diante de falhas e reentregas, handoff com contexto, memória entre interações, reprodutibilidade e qualidade da demonstração) e entrega os itens aprovados com testes:

- **marcador de falha por conversa:** `[falha:<modo>]` no texto da mensagem aplica um modo de falha só àquela conversa;
- **confiança da escalação por regra:** base por motivo e ajustes pela evidência, com a explicação no briefing;
- **kit de conformidade do agente:** projeto Python `agent_conformance/` que verifica qualquer agente contra o contrato v1, com um Core falso e tópicos próprios;
- **cenários de demonstração roteirizados:** comandos do simulador de canais com lojista novo e textos fixos, conferidos no canal e no Core (`bin/rails demo:check`).

Nada muda em `core/app/`, no contrato (`contracts/v1/`) nem no banco.

## Onde fica no fluxo

```text
Simulador (scenario <nome>) → Core → Broker → agent.inbound → agent-mock → agent.outbound → Broker → Core → canal
        │  confere received.jsonl                       │ marcador e confiança                         │
        └──────────── imprime ────────────► bin/rails demo:check (só leitura) ◄──────────────────────────┘

agent-conformance (Core falso) → conformance.inbound → agent-mock-conformance → conformance.outbound → agent-conformance
```

O marcador e a confiança ficam dentro da decisão do agente mock. Os cenários usam o caminho completo da plataforma e conferem as duas pontas: o que chega ao lojista e o que fica gravado no Core. O kit roda fora do ambiente padrão, no profile `conformance`, e não toca nos tópicos `agent.*`.

## Por que existe e que valor gera

**Falha numa conversa escolhida.** `AGENT_FAILURE_MODE` e `AGENT_FAILURE_RATE` valem para o processo inteiro: para demonstrar uma ação desatualizada, todas as conversas sofrem a falha. O marcador isola uma conversa da demonstração e mantém a decisão dependente só do texto, então a mesma mensagem tem sempre o mesmo efeito.

**Briefing legível.** Uma confiança fixa por motivo não diz nada sobre a evidência do caso. Com a regra, o número cai quando falta informação ou o problema é recorrente, e a linha de `attempts` diz por quê; o analista lê o cálculo no cartão do handoff (diferencial 1).

**Agente substituível.** O kit verifica o agente pelo mesmo contrato que o Core e o Broker usam, sem exigir determinismo. Um agente real com LLM passa pelo mesmo teste que o mock, o que sustenta a aderência à estrutura de referência: help desk, webhooks, broker, Kafka, agente.

**Demonstração reprodutível.** Cada cenário exercita um caminho da plataforma (resposta, handoff, reabertura, memória, duplicação, contexto desatualizado, falta de resposta, atraso) com textos fixos e um lojista novo, e diz em linhas `ok` ou `falhou` se o caminho aconteceu. O handoff, a reabertura e a recusa da ação desatualizada não aparecem ao lojista; o `demo:check` confere esses efeitos no Core.

## Decisões por item

| Item | Decisão | Justificativa | Esforço | Partes afetadas |
| - | - | - | - | - |
| Kit de conformidade do agente | Entra, verificando o **agente** | Prova que o agente real substitui o mock e é verificado pelo mesmo contrato; reforça aderência à arquitetura de referência e robustez | Médio | Projeto novo `agent_conformance/`, agente mock (tópicos configuráveis), Compose, `infra/redpanda` |
| Modos de falha por conversa | Entra, por **marcador no texto** | A taxa global não isola uma conversa da demonstração; o marcador mantém a decisão dependente só do texto | Baixo | Agente mock, simulador (textos dos cenários) |
| Escalação rica e determinística | Entra: **confiança por regra** (base mais ajustes), com a explicação em `attempts` | A confiança fixa por motivo não reflete a evidência; a explicação torna o número legível no cartão do diferencial 1 | Baixo | Agente mock |
| Uso visível da memória | Não entra: já atendido | O prefixo da memória no `reply` é entregue pela F12, e a decisão do agente já usa a memória do contexto | Nenhum | Nenhuma |
| Cenários de demonstração roteirizados | Entra, com conferência **no canal e no Core** | Reprodutibilidade e qualidade da demonstração; o handoff e a reabertura não aparecem ao lojista e precisam da conferência no Core | Médio | Simulador, task do Core |

Ficam de fora o modo de falha por marca, a verificação do Core pelo kit, a ação do analista nos cenários, a troca de canal com lojista novo, o marcador no `channel-simulator send` e um campo estruturado dos fatores de confiança no contrato (seção "Limitações").

## Como funciona

### Marcador de falha

`failure.marker(text)` (`agent_mock/src/agent_mock/failure.py`) procura no texto decidido os marcadores `[falha:drop]`, `[falha:duplicate]`, `[falha:stale]`, `[falha:delay]` e `[falha:delay=<ms>]`, em minúsculas, pela expressão `\[falha:(drop|duplicate|stale|delay)(?:=(\d+))?\]`. Devolve o primeiro marcador válido e o texto sem os marcadores válidos, com os espaços repetidos reduzidos a um e as pontas aparadas.

| Texto | Marcador | Texto decidido |
| - | - | - |
| `Oi, tudo bem? [falha:drop]` | `drop` | `Oi, tudo bem?` |
| `[falha:delay=50000] Oi` | `delay`, 50000 ms | `Oi` |
| `[falha:duplicate] Oi [falha:delay=10]` | `duplicate` (vale o primeiro) | `Oi` |
| `Oi [falha:drop=10]` | nenhum: `=<ms>` só vale com `delay` | sem mudança |
| `Oi [FALHA:drop]` | nenhum: só minúsculas | sem mudança |

No `processor.py`, depois dos descartes por mensagem mais nova e por estado:

1. `decision.decided_text` dá o texto da mensagem com a `sequence` do evento;
2. `failure.marker` separa o marcador do texto;
3. `decision.decide(..., text=texto_sem_marcador)` decide sobre o texto limpo: intenção, entidades, sentimento e memória;
4. com marcador, o modo dele vale para o evento, sempre, sem consultar `AGENT_FAILURE_MODE` nem `AGENT_FAILURE_RATE`; sem marcador, vale a configuração, como na F10;
5. `delay` soma à latência o valor do marcador ou, sem valor, `AGENT_FAILURE_DELAY_MS`; `drop`, `duplicate` e `stale` seguem a F10.

O log do evento afetado leva `failure` com o modo e `failure_source` com a origem (`marker` ou `config`). O Core grava a mensagem com o marcador, e o analista o vê no histórico. Os marcadores não são palavras do classificador do Core: um texto com marcador cai na mesma categoria do texto sem ele, o que foi conferido com `Routing::Classifier.call` para todos os textos dos cenários, nas duas marcas.

### Confiança da escalação

`_Decider.confidence(reason)` (`agent_mock/src/agent_mock/decision.py`) calcula a confiança do `escalate` e a linha que a explica:

1. base pelo motivo (`CONFIDENCE_BASE`);
2. menos 0,15 quando a intenção é `repasse` e falta a `data` que `consultar_repasse` aceitaria;
3. menos 0,1 quando `memory.previous` acha conversa do mesmo assunto na janela `AGENT_MEMORY_WINDOW_DAYS` (problema recorrente);
4. limite em 0,05 e 0,95 e arredondamento a 2 casas.

| Motivo | Base | Valores no mock |
| - | - | - |
| `transacao_contestada` | 0,8 | 0,8 ou 0,7 |
| `maquininha_com_defeito` | 0,8 | 0,8 ou 0,7 |
| `transacao_nao_localizada` | 0,5 | 0,5 ou 0,4 |
| `repasse_nao_localizado` | 0,5 | 0,5 ou 0,4 |
| `intencao_nao_identificada` | 0,2 | 0,2 (a intenção `desconhecida` não tem assunto na memória) |

`context.confidence` recebe o valor, e a linha da explicação vai ao fim de `attempts`, em português nos dois locales, com vírgula decimal e a data UTC da conversa da memória: `Confiança 0,4: base 0,5 por repasse_nao_localizado; -0,1 conversa do mesmo assunto em 03/11/2026`; sem ajuste, `Confiança 0,8: base 0,8 por transacao_contestada`. O próximo passo sugerido segue fixo por motivo, e o schema `action` não muda.

Com as ferramentas falsas, `consultar_repasse` sem data recebe sempre a entrada `{}` e devolve `pago`, então repasse sem data nunca escala no mock: os valores 0,35 e 0,25 do ajuste da data valem pela regra e são testados chamando `_Decider.confidence` direto.

### Tópicos configuráveis

`Settings` (`agent_mock/src/agent_mock/config.py`) lê `AGENT_INBOUND_TOPIC` e `AGENT_OUTBOUND_TOPIC`, com padrão `agent.inbound` e `agent.outbound`; presentes e vazios são erro de configuração. O `runner.py` assina e publica nos tópicos de `Settings`. O `agent-mock` do ambiente padrão não recebe as duas variáveis e usa os padrões; o `agent-mock-conformance` usa os tópicos do kit.

### Kit de conformidade

O kit (`agent_conformance/`) é independente do agente mock e roda no contêiner `agent-conformance`:

| Arquivo | Papel |
| - | - |
| `src/agent_conformance/config.py` | Único ponto de leitura de configuração |
| `src/agent_conformance/signature.py` | Conferência do HMAC-SHA256 do contrato, com a janela de 300 s |
| `src/agent_conformance/fake_core.py` | Core falso em aiohttp: responde à `context_url` com o corpo programado por conversa (ou uma sequência de respostas), confere assinatura, marca do caminho e `traceparent` e registra cada leitura |
| `src/agent_conformance/kafka.py` | Produtor em `conformance.inbound` (valor no schema `webhook.message-created`, chave `conversation_id`, headers do schema `kafka.inbound-headers`, `acks=all`) e coletor de `conformance.outbound`, sem grupo, a partir do fim, com as ações separadas por `conversation_id` |
| `src/agent_conformance/builders.py` | Eventos, headers e contextos válidos, com `conversation_id`, `event_id` e trace novos a cada caso |
| `tests/conftest.py` | Core falso, produtor, coletor, schemas e vetores de `CONTRACTS_PATH`; espera o agente responder a um evento de aquecimento, até 90 s, antes do primeiro caso |
| `tests/test_conformance.py` | Casos de conformidade |
| `tests/test_signature.py` | Vetores de assinatura, recusas da conferência e regra da `Idempotency-Key` pelos vetores |

Cada caso usa uma conversa nova, programa o contexto no Core falso, publica um ou mais eventos e espera as ações dessa conversa (até `CONFORMANCE_ACTION_TIMEOUT_SECONDS`) ou a ausência delas: o kit espera a leitura do contexto e depois `CONFORMANCE_QUIET_SECONDS` sem ação.

| Caso | Confere |
| - | - |
| Leitura do contexto | `GET` assinado conforme o contrato, marca no caminho, `traceparent` com o mesmo `trace_id` do header do evento |
| Ação válida | Valor no schema `action`; chave `conversation_id`; headers no schema `kafka.outbound-headers`; `inbound_event_id`, `brand`, `conversation_id` e `based_on_sequence` do evento; `timestamps.broker_received_at` igual ao header e `kafka_appended_at` igual ao timestamp do registro (`LogAppendTime`, devolvido na confirmação da publicação); `traceparent` com o mesmo `trace_id` |
| Reentrega | O mesmo evento duas vezes gera ações com a mesma `Idempotency-Key` |
| Mensagem mais nova | Contexto com mensagem do lojista de `sequence` maior: nenhuma ação |
| Conversa fora da IA | Contexto com a conversa em `awaiting_human`: nenhuma ação |
| Erro permanente | Contexto `404`: nenhuma ação; o evento seguinte, de outra conversa, recebe ação |
| Erro transitório | Contexto `503` e depois `200`: uma ação, depois de pelo menos duas leituras |
| Escalação | Texto sem intenção: se a ação é `escalate`, o `context` tem todos os campos e `confidence` entre 0 e 1; outro agente que responda de outra forma tem o caso pulado |

O kit não exige determinismo: confere forma, coerência e comportamento observável. O processo termina com o código do pytest, e o Compose devolve esse código com `--exit-code-from agent-conformance`.

### Cenários de demonstração

`channel_simulator/src/channel_simulator/scenarios.py` define cada cenário de forma declarativa (canal, passos com texto e marcador, respostas esperadas na ordem e silêncio depois do passo) e o executor `run_scenario`. O executor cria um lojista novo (`personas.new_contact`, com a semente e o `run_id`), envia cada passo por `send_one`, acompanha `received.jsonl` filtrando pelo destinatário do lojista (no WhatsApp, pelos dígitos do número) e imprime uma linha `ok` ou `falhou` por expectativa. Os textos são fixos por locale e foram conferidos no classificador do Core e no `intents.py` do agente.

| Cenário | Canal | Passos | No canal | No Core (`demo:check`) |
| - | - | - | - | - |
| `reply` | whatsapp | taxas | resposta com as taxas da marca | conversa `with_ai`; um `agent.reply`; `message.delivered` |
| `handoff` | chat | mensagem sem intenção | nenhuma resposta em 10 s | `awaiting_human` na fila de escalação da fila de origem (ou na mesma, sem ela); `Handoff` `intencao_nao_identificada` com confiança 0,2 e a explicação em `attempts`; `conversation.escalated` |
| `reopen` | chat | taxas; agradecimento; taxas | taxas; nada em 5 s; taxas sem prefixo | `conversation.resolved` e depois `conversation.reopened`; `with_ai`; dois `agent.reply` |
| `memory`, parte 1 | chat | taxas; agradecimento | taxas; nada em 5 s | imprime o `memory:demo_close` e o comando da parte 2 |
| `memory`, parte 2 | chat | taxas, mesmo lojista | taxas, começando com o prefixo da memória | primeira conversa `closed`, segunda `with_ai`; `customer_memory`; `agent.reply` com o prefixo |
| `failure-duplicate` | chat | saudação com `[falha:duplicate]` | uma resposta e nada em 10 s | um `agent.reply`; uma linha em `processed_events` |
| `failure-stale` | chat | saudação; saudação com `[falha:stale]` | boas-vindas; espera; nada em 50 s | SLA de 1 min; `agent.action.stale`; `conversation.escalated` `ai_timeout`; `awaiting_human` |
| `failure-drop` | chat | saudação com `[falha:drop]` | espera; nada em 50 s | SLA de 1 min; nenhum evento de ação do agente; mensagem `system` `ai_timeout_wait`; `conversation.escalated` `ai_timeout` |
| `failure-delay` | chat | saudação com `[falha:delay=50000]` | espera; boas-vindas | SLA de 1 min; espera antes do `agent.reply`; `with_ai`; nenhum `conversation.escalated` |

Os textos dos cenários de timeout são saudações sem categoria no Core e caem na regra genérica, que recebe SLA de 1 min pelo `panel:demo_sla`. Com esse SLA, a espera sai entre 30 e 45 s (a varredura roda a cada 15 s) e a escalação entre 60 e 75 s; o silêncio de 50 s depois da espera cobre a escalação antes do `demo:check`. No `failure-delay`, o `reply` sai em cerca de 51 s (50 s de atraso mais o `GET` do contexto), antes da escalação.

O `memory` tem duas partes: a parte 1 grava `runs/<run_id>/scenario.json` e imprime o `memory:demo_close` com o `conversation_id` devolvido pelo chat e o comando da parte 2; a parte 2 (`--continue <run_id>`) lê o lojista desse arquivo e imprime o `demo:check` com os `EXTERNAL_IDS` das duas partes.

### `demo:check`

`core/lib/tasks/demo.rake` (módulo `DemoCheck`) recebe `SCENARIO`, `BRAND`, `CHANNEL` e `EXTERNAL_IDS`. Em `Tenancy.with_brand`, acha cada `Message` por `(channel, external_id)` (índice único em `messages`), chega às conversas e ao lojista e confere as expectativas do cenário, definidas em Ruby, a partir do estado das conversas, de `handoffs`, `processed_events`, `customer_memories` e `audit_events`. Imprime uma linha `ok` ou `falhou` por expectativa, com o valor encontrado, e termina com código 1 quando alguma falha. Nos cenários de timeout, confere o `sla_minutes` do último `conversation.routed` e, fora de 1, lembra o `panel:demo_sla`. A task só lê: não grava nada.

## O que o sistema garante

- O evento com marcador é sempre afetado pelo modo do marcador, e a decisão é a mesma do texto sem marcador.
- Sem marcador, o modo de falha segue `AGENT_FAILURE_MODE` e `AGENT_FAILURE_RATE`, como na F10.
- A mesma entrada gera a mesma confiança e a mesma linha de explicação; a confiança fica entre 0,05 e 0,95 e passa no schema `action`.
- O `agent-mock` padrão consome `agent.inbound` e publica em `agent.outbound`; o kit usa só `conformance.inbound` e `conformance.outbound`.
- Cada cenário termina com código 0 quando todas as expectativas no canal se cumprem, e o `demo:check` termina com código 0 quando todas as expectativas no Core se cumprem.
- O `demo:check` não grava nada no banco.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Agente mock com modos de falha configuráveis | Marcador por conversa, acima da configuração | Modos por configuração (F10) |
| Handoff com resumo e contexto | Confiança por regra explicada no briefing | Cartão do handoff e avaliação (F11) |
| Integração com o atendente por webhooks e broker | Kit que verifica qualquer agente pelo contrato v1 | Contrato (F3), Broker (F9), API de ações (F8) |
| Memória e contexto entre interações | Cenários `reopen` e `memory`, conferidos no canal e no Core | Memória do lojista (F12) |
| Rastreabilidade e auditoria | `demo:check` lendo `audit_events`, `handoffs` e `processed_events` | Auditoria (F2) |

### No experimento técnico

A carga do experimento usa as falhas de processo (`docker restart` e `docker kill`), não os modos do agente. O kit e os cenários servem antes do experimento: o kit confirma que o agente cumpre o contrato, e os cenários confirmam cada caminho da plataforma de ponta a ponta com dados novos.

## Diferenciais

| Diferencial | O que esta parte faz por ele |
| - | - |
| 1 · Briefing de handoff | A confiança vem de uma regra, e a última linha de "O que a IA tentou" explica o cálculo; no painel, o cartão do cenário `handoff` mostra "Confiança 20%" e a linha `Confiança 0,2: base 0,2 por intencao_nao_identificada` |
| 4 · Modos de falha do agente mock | O marcador escolhe a conversa da demonstração; os cenários `failure-*` exercitam a idempotência, a recusa `409 stale` e a varredura do timeout, cada um conferido no Core |

## Limitações

- **Modo de falha por marca:** não existe; o marcador por conversa cobre a demonstração.
- **Ajuste da data na confiança:** com as ferramentas falsas, o repasse sem data não escala, e o ajuste aparece só nos testes da decisão.
- **Kit verificando o Core:** o kit verifica o agente; `409 stale`, `409 rejected` e a idempotência do Core ficam no RSpec da F8.
- **Ação do analista nos cenários:** pegar, responder, avaliar e resolver ficam manuais no painel.
- **Troca de canal com lojista novo:** cada lojista novo tem uma identidade por canal; a troca de canal fica no `scenario cross-channel`, com lojista das seeds.
- **Marcador no `channel-simulator send`:** não existe; a carga não usa os modos do agente.
- **Fatores da confiança no contrato:** a explicação fica em `attempts`, como texto, sem campo estruturado em `contracts/v1/`.
- **Tempos dos cenários de timeout:** dependem da varredura a cada 15 s e do SLA de 1 min; o `failure-drop` e o `failure-stale` levam cerca de 80 a 100 s.

## Operação

### Processos

| Serviço | Comando | Profile |
| - | - | - |
| `agent-conformance` | `pytest`, com o Core falso na porta 8080 | `conformance` |
| `agent-mock-conformance` | `agent-mock run`, grupo `cloudesk-agent-conformance`, tópicos `conformance.*`, `CORE_URL=http://agent-conformance:8080`, `AGENT_FAILURE_MODE=none`, `AGENT_LATENCY_MS=0` | `conformance` |

Os dois não sobem com `docker compose up` sem o profile. Os tópicos `conformance.inbound` (6 partições, `LogAppendTime`) e `conformance.outbound` (6 partições) são criados pelo `redpanda-init`, junto dos tópicos `agent.*`.

### Configuração

Agente mock:

| Variável | Uso | Padrão |
| - | - | - |
| `AGENT_INBOUND_TOPIC` | Tópico de entrada; vazio é erro de configuração | `agent.inbound` |
| `AGENT_OUTBOUND_TOPIC` | Tópico de saída; vazio é erro de configuração | `agent.outbound` |

Kit (`agent_conformance/src/agent_conformance/config.py`):

| Variável | Uso | Padrão |
| - | - | - |
| `KAFKA_BROKERS` | Endereço do Kafka | `redpanda:9092` |
| `CONFORMANCE_INBOUND_TOPIC` | Tópico dos eventos | `conformance.inbound` |
| `CONFORMANCE_OUTBOUND_TOPIC` | Tópico das ações | `conformance.outbound` |
| `CONFORMANCE_CONTEXT_SECRET` | Segredo do `GET` do contexto; o Compose passa o `AGENT_CONTEXT_SECRET` | `.env` |
| `CONFORMANCE_CORE_PORT` | Porta do Core falso | `8080` |
| `CONFORMANCE_ACTION_TIMEOUT_SECONDS` | Espera máxima por uma ação ou leitura do contexto | `15` |
| `CONFORMANCE_QUIET_SECONDS` | Tempo sem ação que confirma a ausência de ação | `5` |
| `CONTRACTS_PATH` | Pasta do contrato | `/contracts` |

Dependências do kit fixadas no `agent_conformance/pyproject.toml`, com Python 3.13, nas mesmas versões do agente mock: `aiokafka` 0.15.0, `aiohttp` 3.14.5, `pytest` 9.2.0, `pytest-asyncio` 1.5.0 e `jsonschema` 4.26.0.

### Kit de conformidade

```text
docker compose --profile conformance up --build --abort-on-container-exit --exit-code-from agent-conformance agent-conformance agent-mock-conformance
```

Para verificar outro agente, ele ocupa o lugar do `agent-mock-conformance`: consome `conformance.inbound`, publica em `conformance.outbound` e lê o contexto em `http://agent-conformance:8080`, com o mesmo segredo.

### Cenários de demonstração

Com o ambiente de pé, o `agent-mock` padrão e o `channel-simulator serve`:

```text
docker compose exec channel-simulator channel-simulator scenario reply --brand infinitepay
docker compose exec web bin/rails demo:check SCENARIO=reply BRAND=infinitepay CHANNEL=whatsapp EXTERNAL_IDS=<id>

docker compose exec channel-simulator channel-simulator scenario memory --brand infinitepay
docker compose exec web bin/rails memory:demo_close CONVERSATION=<id>
docker compose exec channel-simulator channel-simulator scenario memory --brand infinitepay --continue <run_id>

docker compose exec web bin/rails panel:demo_sla BRAND=infinitepay MINUTES=1
docker compose exec channel-simulator channel-simulator scenario failure-drop --brand infinitepay
docker compose exec web bin/rails demo:check SCENARIO=failure-drop BRAND=infinitepay CHANNEL=chat EXTERNAL_IDS=<id>
docker compose exec web bin/rails panel:demo_sla_reset BRAND=infinitepay
```

Cada cenário imprime o comando exato do passo seguinte. Com `--brand jim`, os textos e as respostas esperadas ficam em en-US.

### Verificação

```text
docker compose run --rm agent-mock pytest
docker compose exec channel-simulator pytest
docker compose exec -e RAILS_ENV=test web bundle exec rspec spec/tasks/demo_check_spec.rb
```

| Arquivo | O que comprova |
| - | - |
| `agent_mock/tests/test_failure.py` | Marcador de cada modo; `delay` com e sem valor; `=<ms>` fora do `delay`, maiúsculas e outros colchetes que ficam no texto; dois marcadores; espaços reduzidos; texto sem marcador sem mudança |
| `agent_mock/tests/test_processor.py` | Marcador acima de `AGENT_FAILURE_MODE=none`, de `AGENT_FAILURE_RATE=0` e de outro modo; `delay=<ms>` e `delay` sem valor; `stale` por marcador com `sequence` 1 e maior; marcador lido no texto do contexto; decisão igual à do texto sem marcador; `failure_source` no log |
| `agent_mock/tests/test_decision.py` | Confiança de cada motivo; memória do mesmo assunto na janela; fora da janela e de outro assunto sem ajuste; repasse sem data e os dois ajustes pela decisão direta; limites; explicação como última linha, em português nos dois locales; `decide` com `text`; mesma entrada, mesma confiança |
| `agent_mock/tests/test_action.py` | Escalações com a confiança por regra, inclusive com o ajuste da memória, no schema `action` |
| `agent_mock/tests/test_config.py` | Tópicos: padrão, valor lido e vazio recusado |
| `agent_mock/tests/test_offsets.py` | O runner assina e publica nos tópicos de `Settings` |
| `agent_conformance/tests/test_conformance.py` | Os casos de conformidade contra o agente sob teste |
| `agent_conformance/tests/test_signature.py` | Vetores de assinatura e de `Idempotency-Key`; recusas por janela, assinatura, segredo, header ausente e timestamp inválido |
| `channel_simulator/tests/test_scenarios.py` | Textos nos dois locales; marcadores dos cenários de falha; expectativa cumprida, resposta faltando ou diferente, resposta a mais no silêncio, envio com erro, código de saída; `scenario.json`; lojista novo por execução; `memory` em duas partes; `demo:check` impresso |
| `core/spec/tasks/demo_check_spec.rb` | Cada cenário montado com `Conversations::Intake`, `Agents::ActionProcessor`, `Conversations::AiTimeoutSweepJob` e as tasks de demonstração passa e, com uma expectativa quebrada, falha; mensagem não encontrada; cenário, canal e marca desconhecidos; aviso do SLA; a task não grava nada |

No Compose:

- o kit termina com código 0 contra o agente mock, e o nome `agent-conformance` resolve na rede do Compose;
- `rpk topic describe conformance.inbound -c` mostra `message.timestamp.type` `LogAppendTime`;
- `rpk group describe cloudesk-agent` mostra o `agent-mock` padrão só em `agent.inbound`;
- os oito cenários, nas duas marcas, terminam com código 0 no simulador e no `demo:check` impresso, os de timeout com o `panel:demo_sla` de 1 min;
- no painel, a conversa do cenário `handoff` mostra o cartão com "Confiança 20%" e a linha da confiança em "O que a IA tentou".

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Contrato (F3) | O kit valida as ações e os headers pelos schemas e vetores de `contracts/v1/`; o contrato não muda |
| Simulador de canais (F5) | Recebe os cenários de demonstração; o `send` e o `cross-channel` seguem iguais |
| API de ações e contexto (F8) | O `demo:check` lê os efeitos das ações aceitas e recusadas; o kit imita a `context_url` |
| Broker (F9) | Os cenários passam pelo Broker; o kit fala direto com o Kafka |
| Agente mock (F10) | Recebe o marcador, a confiança por regra e os tópicos configuráveis |
| Handoff, painel e timeout (F11) | Os cenários `handoff` e `failure-*` exercitam a escalação e a varredura; o cartão mostra a confiança explicada |
| Memória e contexto (F12) | Os cenários `reopen` e `memory` exercitam a memória e a reabertura; a confiança usa a mesma `memory.previous` do prefixo |
| Experimento (F18) | O kit e os cenários confirmam o comportamento antes da carga |

## Fontes

- TAPI, critérios de avaliação e diferenciais
- `documents/arquitetura.md`, seções "Contrato com o agente", "Kit de conformidade do agente", "Timeout do agente", "Componentes simulados" e "Diferenciais"
- `documents/fases/04-contrato-de-integracao.md`, seções "Assinatura", "Headers das mensagens Kafka" e "`Idempotency-Key`"
- `documents/fases/06-simulador-de-canais.md`, seção "Cenários de demonstração"
- `documents/fases/11-agente-mock.md`, seções "Um evento, do consumo à publicação" e "Tabela de decisão"
- `documents/fases/12-handoff-painel-e-timeout.md`
- `documents/fases/13-memoria-e-contexto.md`

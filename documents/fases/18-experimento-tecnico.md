# Cloudesk · Experimento técnico

## O que é

O experimento mede o Cloudesk sob carga e sob falhas de processo. Ele avalia, cada uma separadamente, as hipóteses de volume e robustez (H1 a H4, com alvo de 250 msg/s) e três hipóteses na média do volume de referência (H5 a H7, 8 msg/s). O roteiro, o k6 e a análise ficam em `experiment/`, e os comandos, em `experiment/README.md`.

Veredito da sessão `20261125T004706Z`, em uma única máquina local:

| # | Hipótese | Veredito | Execução |
| - | - | - | - |
| H1 | 250 msg/s por 15 min sem acúmulo crescente de backlog | Refutada | `meta-2` |
| H2 | A 250 msg/s, p95 entrada → Kafka < 300 ms | Refutada | `meta-2` |
| H3 | Com o Broker reiniciado e um worker morto, 0 mensagens perdidas e 0 duplicadas | Confirmada a 24 msg/s | `h3-2` |
| H4 | A 250 msg/s, p95 ponta a ponta < 1 s | Refutada | `meta-2` |
| H5 | A 8 msg/s por 3 min, os critérios da H1 | Refutada | `escada-8-2` |
| H6 | A 8 msg/s, p95 entrada → Kafka < 300 ms | Confirmada | `escada-8-2` |
| H7 | A 8 msg/s, p95 ponta a ponta < 1 s | Confirmada | `escada-8-2` |

## Onde fica no fluxo

```text
k6 → web-lb → web → jobs-webhooks → broker-web → agent.inbound → agent-mock
                                                                      │
channel-simulator ← jobs-default ← web (API de ações) ← broker-consumer ← agent.outbound
        │
        └→ received.jsonl → reconciliação ← experiment:export (audit_events, messages)
```

A carga entra pelos endpoints reais de WhatsApp e chat, e as respostas saem pelo canal simulado. O e-mail é um teste funcional à parte.

## Por que existe e que valor gera

**Evidência em vez de premissa.** As metas de volume são premissas do projeto. O experimento mostra onde elas valem nesta máquina e onde não valem.

**Perda e duplicação conferidas por mensagem.** Cada envio tem identificador único e é reconciliado com o estado do Core e com as respostas recebidas no canal.

**Honestidade.** Os critérios são numéricos e fixados antes da medida. Toda execução é listada, inclusive as que não contam como medida.

## Como funciona

### Hipóteses e critérios

| Critério | Como decide |
| - | - |
| H1 e H5 | (a) Descartado o primeiro minuto, o limite superior do IC 95% da inclinação do backlog fica abaixo de 1% da taxa; (b) pelo menos 99% da taxa pedida é aceita, com `dropped_iterations` e falhas abaixo de 1%; (c) o backlog zera em até 60 s |
| H2 e H6 | Pelo menos 95% das mensagens até 0,3 s em `cloudesk_broker_inbound_latency_seconds`; a mensagem que não chegou ao Kafka conta como acima da meta. A conferência é exata, por `audit_events` |
| H3 | 0 perdidas, 0 duplicadas e `robustness:check` com código 0 |
| H4 e H7 | p95 exato de `audit_events`, menos a latência artificial. A mensagem sem resposta própria e coberta por ação mais nova sai do universo e é contada à parte; a sem resposta e sem cobertura entra como infinita |

Backlog são os jobs prontos e em execução de `webhooks`, `channels` e `default`, mais o lag de `cloudesk-agent` e `cloudesk-broker`. Perdida é a mensagem aceita sem `Message` no Core, sem ação aceita com `based_on_sequence` maior ou igual até a coleta, ou com escalação `ai_timeout`. Duplicada é o `core_message_id` recebido mais de uma vez no canal.

H5, H6 e H7 são definidas em 25/11/2026 (UTC), depois do ensaio e dos pilotos (5, 24, 40 e 80 msg/s) e antes da primeira execução a 8 msg/s. São informadas pelos pilotos, e a carga delas é a média em horário comercial do volume de referência. Os limites são os mesmos de H1, H2 e H4, e H1 a H4 valem como formuladas na arquitetura. Os 3 min delas não equivalem aos 15 min da H1.

### Carga

- k6 2.4.0, taxa de chegada constante, sem reenvio, timeout de 10 s.
- Conversa de 5 mensagens do lojista, 20 s entre elas: 4 perguntas respondidas pela IA e um agradecimento, que resolve. Sem escalação.
- 90% WhatsApp, com lojista novo por conversa, e 10% chat, com grupo fixo aquecido; 70% infinitepay e 30% jim.
- `AGENT_LATENCY_MS=200`, com uma réplica do agente.
- Lojistas sem segmento, que não chegam às filas com transbordo. Cada etapa confere que 100% das conversas são roteadas à IA.

### Etapas

| Etapa | Carga |
| - | - |
| `ensaio` | 5 msg/s por 1 min |
| `piloto` | 3 min por rodada; escolhe réplicas e a taxa da H3 |
| `h3` | 8 min à maior taxa sustentada no piloto (24 msg/s) |
| `escada` | 8 e 24 msg/s por 3 min, 80 por 5 min |
| `meta` | 250 msg/s por até 15 min; para no minuto 5 se os critérios (a) ou (b) da H1 já reprovam |
| `extra` | 40 msg/s por 5 min, porque 250 e 80 não são sustentados |
| `email` | 10 e-mails, 1 por segundo |

Falhas da H3, contadas do início do k6: minuto 2, `docker restart` de todas as réplicas do `broker-web`; minuto 4, de todas as do `broker-consumer`; minuto 5,5, `docker kill` de uma réplica do `jobs-webhooks`, religada no minuto 7. Os horários reais ficam em `faults.json`.

### Guardas

A etapa é interrompida com menos de 500 MB disponíveis no Docker em duas amostras, ou com mais de 20% de respostas diferentes de 200 no último minuto, e então não conta como medida. A 250 msg/s, a segunda guarda interrompe a `meta-1` depois de 13,5 s de carga (130 de 536 respostas). Por isso a `meta-2` roda com `experiment/run.sh meta sem-guarda-de-erros`, que desliga só essa guarda e registra `error_guard` em `conditions.json`. Essa mudança de roteiro é posterior à `meta-1`, e os critérios das hipóteses são os mesmos.

## Condições

| Item | Valor |
| - | - |
| Máquina | Notebook com Windows e WSL2; 12 CPUs lógicas e 7,6 GiB visíveis ao Docker 29.8.2 |
| Gerador de carga | Na mesma máquina |
| Réplicas | `web=6`, `jobs-webhooks=2`, `jobs-default=2`, `broker-web=2`, `broker-consumer=2`, `agent-mock=1`; `web=4` no ensaio e nos pilotos 1 e 2 |
| Rails | `RAILS_ENV=development` com `CLOUDESK_LOAD_PROFILE=1`, `RAILS_MAX_THREADS=3`, YJIT desligado |
| Código | O copiado na imagem, sem pasta montada do host |
| Imagem do Core | `6fa9191f808a` no ensaio, pilotos, `h3-1`, `escada-8-1` e `escada-24-1`; `adb0bd40bfab`, com código diferente, em `escada-8-2`, `escada-24-2`, `escada-80-1`, `meta-1`, `meta-2`, `extra-1`, `email-1` e `h3-2` |
| Outros contêineres | `supabase_vector_sunontent`, de outro projeto |

## Resultados

### Todas as execuções da sessão

H1 é a coluna "sup": limite superior do IC 95% da inclinação do backlog, em mensagens por segundo, seguido do limite.

| Execução | msg/s | Medida | H1 | Sup (limite) | Aceita | H2 até 0,3 s | p95 entrada → Kafka | H4 p95 | Perdidas / duplicadas |
| - | - | - | - | - | - | - | - | - | - |
| `ensaio-1` | 5 | sim | sem amostras | - | - | 99,7% | 0,19 s | 0,41 s | 0 / 0 |
| `piloto-1` (`web=4`) | 80 | sim | não | 44,5 (0,8) | 61,4% | 74,9% | 0,44 s | 129,8 s | 0 / 0 |
| `piloto-2` (`web=4`) | 40 | sim | não | 32,8 (0,4) | 97,7% | 80,2% | 0,41 s | 69,3 s | 0 / 0 |
| `piloto-3` | 40 | sim | não | 4,6 (0,4) | 99,7% | 64,7% | 0,51 s | 28,8 s | 0 / 0 |
| `piloto-4` | 24 | sim | sim | 0,10 (0,24) | 100% | 82,8% | 0,47 s | 5,0 s | 0 / 0 |
| `h3-1` | 24 | sim | não | 2,74 (0,24) | 99,8% | 57,1% | 17,7 s | 19,5 s | 0 / 0 |
| `escada-8-1` | 8 | não | - | - | - | 98,2% | 0,24 s | 0,50 s | 0 / 0 |
| `escada-8-2` | 8 | sim | não | 0,16 (0,08) | 100% | 99,5% | 0,19 s | 0,43 s | 0 / 0 |
| `escada-24-1` | 24 | sem resumo | - | - | - | - | - | - | - |
| `escada-24-2` | 24 | sim | não | 0,54 (0,24) | 99,9% | 81,7% | 0,48 s | 4,8 s | 0 / 0 |
| `escada-80-1` | 80 | sim | não | 38,0 (0,8) | 67,4% | 1,0% | 38,9 s | 181,0 s | 0 / 0 |
| `meta-1` | 250 | não | - | - | - | 1,9% | 0,97 s | 23,5 s | 0 / 0 |
| `meta-2` | 250 | sim | não | 61,4 (2,5) | 17,0% | 0,9% | 67,3 s | infinito | 3.612 / 0 |
| `extra-1` | 40 | sim | não | 25,0 (0,4) | 99,3% | 40,5% | 0,74 s | 89,0 s | 0 / 0 |
| `h3-2` | 24 | sim | sim | 0,13 (0,24) | 99,96% | 71,5% | 0,69 s | 7,3 s | 0 / 0 |

- `escada-8-1` é interrompida à mão com cerca de 42 s, sem olhar o resultado.
- `escada-24-1` é encerrada junto do roteiro: não tem `summary.json`, e o `concluida` do `conditions.json` dela é só o valor inicial gravado pelo roteiro. Não é uma medida.
- O p95 de entrada → Kafka usa só as mensagens com carimbo do Kafka em `audit_events`; a fração até 0,3 s conta as que faltam.
- A `meta-2` termina sem drenar em 180 s, e a coleta é feita com lag de 3.297. As 3.612 "perdidas" do `summary.json` são mensagens sem ação na coleta. Cerca de 1 min depois, com lag 0 em `cloudesk-agent` e 35 em `cloudesk-broker` e `agent.dlq` vazio, a `robustness:check` dá 0 mensagens sem ação, 0 respostas e entregas duplicadas e código 0. Essa task cobre as mensagens enviadas ao agente e aceita `ai_timeout` como desfecho. A saída fica em `meta-2/raw/`, fora do Git. O `summary.json` é o da coleta, sem alteração.

### H1, H2 e H4 a 250 msg/s

Refutadas. O k6 deixa de enviar 62.286 das 81.478 mensagens planejadas (76,4%) até a parada no minuto 5; das 18.907 enviadas, 26,7% falham, com p95 HTTP de 9,9 s. O backlog cresce até 15.218 e não zera. 1.465 envios ficam sem resposta e sem `Message` no Core (`indefinida`), e 3.589 sem resposta têm `Message` gravada. A carga efetiva fica bem abaixo de 250 msg/s: o resultado mostra que a máquina não chega à meta, não como o sistema se comporta com 250 msg/s efetivos.

A meta da H2 vale a 5 e 8 msg/s e não vale de 24 em diante. A da H4, o mesmo.

### H3

Confirmada em duas execuções a 24 msg/s por 8 min, com as mesmas falhas:

| | `h3-1` | `h3-2` |
| - | - | - |
| Enviadas | 11.499 | 11.515 |
| Atendidas | 11.495 | 11.515 |
| Recusadas na entrada (HTTP 500) | 4 | 0 |
| Perdidas / duplicadas | 0 / 0 | 0 / 0 |
| Ações `stale` | 3.289 | 0 |
| `agent.dlq` | 0 | 0 |
| `robustness:check` | código 0 | código 0 |
| Imagem do Core | `6fa9191f808a` | `adb0bd40bfab` |

O veredito é o da última execução medida, `h3-2`, com o código atual. As 4 recusas da `h3-1` têm resposta 500 e nenhuma `Message` no Core: não são perda pela definição, e o lojista recebe erro. Entre as duas execuções muda a imagem do Core, além da variação da máquina; o experimento não separa a contribuição de cada uma. A taxa é a maior sustentada no piloto, não 250 msg/s: a H3 não é testada na carga da H1.

### H5 a H7 a 8 msg/s

As 1.440 mensagens são aceitas e atendidas. A H6 fica com 99,5% até 0,3 s (p95 de 192 ms) e a H7, com p95 de 0,425 s. A H5 é refutada pelo critério (a): a inclinação medida é de -0,0044/s, mas o limite superior do IC 95%, com 9 amostras, é 0,16, acima de 0,08. O backlog máximo é 20 e zera em 30 s. O critério é aplicado como definido, e o resultado indica intervalo largo em 3 min, sem provar acúmulo.

### Capacidade

`capacity` traz `not_sustained_from` 8 e `sustained_up_to` nulo, pelos degraus da escada, da meta e do extra. A 24 msg/s, duas execuções (`piloto-4` e `h3-2`) cumprem os critérios da H1, e duas (`h3-1` e `escada-24-2`) não. O experimento não mede a variabilidade, e por isso não afirma uma capacidade em msg/s.

### E-mail

10 e-mails, 10 atendidos, 0 perdidos, 0 duplicados, `robustness:check` com código 0. São 9 entregas porque o agente responde 9 e escala 1.

### YJIT

A sessão `20261125T015658Z` repete o degrau de 40 msg/s com o YJIT ligado (`EXPERIMENT_YJIT=1`) e `web=6`: aceita 95,9%, limite superior 13,0/s, H2 58,0%, p95 ponta a ponta 29,9 s, 0 perdidas e 0 duplicadas. O `piloto-3`, sem YJIT, tem 99,7%, 4,6/s, 64,7% e 28,8 s. Não há ganho observado, e uma execução de cada não permite concluir piora. Na primeira tentativa dessa sessão, o aquecimento falha com 61 de 80 lojistas respondidos e timeouts; a causa não é comprovada, os logs ficam em `raw/aquecimento-falho-1`, e a repetição, sem mudança, completa. As etapas da sessão principal rodam com o YJIT desligado.

### Sessões descartadas

| Sessão | Por que não conta |
| - | - |
| `20261124T224730Z` | Parte da carga do piloto roda com a máquina em espera. O roteiro registra as entradas e saídas da espera moderna nas condições das sessões seguintes |
| `20261124T234016Z` | O código do Core vem de pasta do Windows montada no contêiner. Uma requisição sem trabalho leva 111 ms com a pasta e 2,5 ms com o código da imagem. Nenhuma taxa é sustentada (24 msg/s: 98,7% aceita, p95 ponta a ponta 84,9 s); 0 duplicadas; a rodada de 40 msg/s não drena e termina com 31 mensagens sem ação na coleta |

As duas ficam em `experiment/results/`, com resumos e condições.

### Gargalo

- A 24 e a 40 msg/s, o acúmulo fica no grupo `cloudesk-broker` (média de 3.262 a 40 msg/s), no trecho do agente até o Core. A 80 e 250, cresce também antes do Kafka: p95 `core_to_broker` de 58 s e 60 s ou mais, com 60 s no último bucket, e o `web` responde com p95 de até 9,9 s.
- O `web` é o serviço de maior CPU (338% na `h3-2`, 445% na `extra-1`, 479% na `meta-2`). Postgres (124% a 138%), `jobs-webhooks` (80% a 149%) e `jobs-default` (14% a 127%) vêm depois. A soma fica perto de 850% de 1200% a 40, 80 e 250 msg/s.
- "A máquina não está esgotada" não é provado por esses números: 12 CPUs lógicas, medição sem o Windows e a VM. As 6 partições de `agent.outbound` processadas em série, a espera do lote no Karafka e a saturação do `web` são candidatos, e o experimento não os separa.

## O que o sistema garante

- Nenhuma mensagem perdida ou duplicada nas execuções com as falhas injetadas da H3.
- Toda execução fica gravada, sem sobrescrita, com as condições.
- Nenhuma escrita no domínio: `experiment:export` só lê, por marca, em `Tenancy.with_brand`.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega |
| - | - |
| Experimento técnico | Hipóteses avaliadas separadamente, método, resultados e limitações |
| Documentação (README) | Metodologia, resultados e limitações |

### No experimento técnico

Esta parte é o próprio experimento; as demais fases entram com o que ele mede (F14) e com o que ele exercita (F4 a F11 e F15).

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 4 · Modos de falha do agente mock | Não entram na carga, que usa falhas de processo |

## Limitações

- **Uma máquina.** Gerador, sistema e observabilidade no mesmo notebook, com 7,6 GiB no Docker. Os números não se transferem para produção.
- **Sem medida de variação.** Uma execução por etapa, com exceções. A 24 msg/s, execuções iguais divergem entre cumprir e não cumprir a H1; aquecimento (48 ou 500 lojistas) e imagem do Core também diferem entre elas.
- **Regra da inclinação.** Com 3 min a 8 e 24 msg/s, são 9 amostras de 15 s. O IC da regressão com amostras autocorrelacionadas é otimista, e o intervalo é largo mesmo assim: a H5 depende dele.
- **Taxa de 250 não alcançada.** O k6 descarta 76% da carga planejada; a medida é de uma carga oferecida menor. A conferência no minuto 5 substitui os 15 min quando a H1 já falhou.
- **Guarda desligada na `meta-2`.** Com ela ligada, 250 msg/s não chega à conferência do minuto 5.
- **H4 e mensagens cobertas.** Com atraso, o lojista manda outra mensagem antes da resposta, e a ação antiga é `stale`. A mensagem coberta sai do universo da H4: a 80 msg/s, são 11.630 contra 1.321 no universo. O p95 descreve só as respondidas.
- **H3 a 24 msg/s**, não a 250. Os 4 HTTP 500 da `h3-1` ficam registrados.
- **Drenagem limitada.** 3 min por degrau, 5 na H3; o restante é pendente na coleta.
- **`received_at`** é carimbado depois do nginx e da fila do Puma.
- **`RAILS_ENV=development`** com perfil de carga, sem YJIT.
- **Carga sintética.** Corpus fixo, sem handoff, agente determinístico, chat em 10% com lojistas reutilizados e histórico crescente, e-mail fora da carga.
- **Transbordo fora da carga.** Os lojistas não têm segmento e não chegam a `ip-financeiro-prioritaria` nem a `jim-finance-priority` (capacidade 20, transbordo para fila humana). O comportamento dessas filas sob carga não é medido.
- **Redpanda** em modo `dev-container`, com um nó; lag amostrado a cada 15 s.
- **Hipóteses na média informadas pelos pilotos.**

## Operação

### Processos

Projeto Compose `cloudesk-experiment` (`compose.yaml` mais `experiment/compose.yaml`), com rede e volumes próprios. Durante a carga, o projeto `cloudesk` fica parado, e os volumes dele não são tocados. Os serviços `k6` e `analysis` ficam no profile `experiment`.

### Configuração

Sem variável nova no `.env`. `EXPERIMENT_YJIT=1` liga o YJIT, `SESSION=<id>` escolhe a sessão, e as réplicas ficam em `replicas.env`.

### Inspeção

`experiment/results/<sessão>/` traz `summary.json`, figuras e uma pasta por execução. `experiment/run.sh analisar <execução>` refaz a análise sobre `raw/`, que fica fora do Git.

### Verificação

RSpec do Core com 1035 exemplos e 0 falhas; pytest da análise com 66 testes e 0 falhas; `lanes_test.js` com todos os `check` aprovados. Depois da carga, o projeto `cloudesk` religado tem as 10.311 linhas de `messages`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Canais (F4) e simulador (F5) | Recebem a carga e registram as respostas |
| Roteamento (F6) | A carga usa lojistas sem segmento, roteados à IA |
| API de ações (F8) e Broker (F9) | Caminho de volta, onde o backlog acumula |
| Agente mock (F10) | 200 ms de latência artificial, sem modo de falha |
| Observabilidade (F14) | Métricas de H1, H2 e H4 e saltos |
| Robustez e escala (F15) | Réplicas, perfil de carga e `robustness:check` |

## Fontes

- `documents/arquitetura.md`, seções "Premissas de volume" e "Experimento técnico: carga + falhas"
- `experiment/README.md`
- `experiment/results/20261125T004706Z/summary.json`
- TAPI

# Cloudesk · API de ações e de contexto

## O que é

A API de ações e de contexto é a porta por onde o agente de IA atua no Cloudesk. Ela dá ao agente dois movimentos, os mesmos de um atendente humano:

- **ler** a conversa antes de decidir, pelo endpoint de contexto;
- **agir** sobre ela, pela API de ações: responder ao lojista (`reply`), escalar para um analista (`escalate`), reclassificar o assunto (`categorize`) ou encerrar o atendimento (`resolve`).

O agente não acessa o banco nem conhece as regras internas da plataforma. Tudo o que ele faz passa por esses dois endpoints, e o Core decide se cada ação vale, executa o efeito e registra a decisão. É assim que o princípio "o agente é um atendente da plataforma" se concretiza: a IA tem as mesmas portas de entrada que um usuário, sujeitas às mesmas regras e à mesma auditoria.

## Onde fica no fluxo

```text
Canal → Core → webhook → Broker → agent.inbound → agente
                                                    │
                     GET context_url  ◄─────────────┤  (lê a conversa)
                                                    │
agente → agent.outbound → Broker → POST /api/v1/agent/actions → Core → canal do lojista
```

O webhook `message.created` avisa o agente de uma mensagem nova e traz a `context_url`. O agente lê o contexto, decide e publica a ação em `agent.outbound`; o Broker entrega a ação ao Core. Esta parte do sistema cobre os dois pontos em que o Core recebe o agente: a leitura do contexto e o recebimento da ação.

## Por que existe e que valor gera

**Correção diante de falhas.** A entrega entre Core, Broker e agente é at-least-once: qualquer salto pode repetir uma mensagem depois de uma queda ou de um retry. A API de ações é a única barreira de deduplicação do sistema. Com ela, a repetição não chega ao lojista, e Broker e agente podem ser reiniciados e escalados sem guardar estado. A hipótese H3 do experimento, nenhuma mensagem perdida nem duplicada com o Broker reiniciado e um worker morto, depende dessa barreira.

**Correção diante da desordem.** Eventos da mesma conversa podem chegar ao agente fora de ordem, porque passam por jobs paralelos com retry antes do Kafka. A API recusa a ação baseada em uma conversa que já mudou, e a resposta ao lojista vem sempre de uma decisão tomada sobre o estado mais recente. A ordem fica garantida pelo estado da conversa, sem depender do transporte.

**Fronteira entre IA e humano.** Quando um analista assume a conversa, ou quando ela é encerrada, nenhuma ação atrasada da IA tem efeito. O lojista não recebe uma resposta automática no meio de um atendimento humano.

**Rastreabilidade.** Cada ação, aceita ou recusada, vira um registro de auditoria com o corpo completo do que o agente enviou: ferramentas consultadas com entradas e saídas, modelo quando o agente o informa e os horários de cada salto. Esse registro é a base da linha do tempo por mensagem e responde, para qualquer resposta dada ao lojista, o que a IA consultou e quanto tempo cada etapa levou.

**Isolamento entre marcas.** Toda leitura e escrita acontece dentro da marca da conversa, com o Row-Level Security do Postgres. O agente de uma marca não lê nem altera conversas de outra, mesmo com um identificador correto em mãos.

## Como funciona

### Autenticação

As duas chamadas são assinadas com HMAC-SHA256 e timestamp, no esquema comum do contrato (`documents/fases/04-contrato-de-integracao.md`): o texto assinado é `<timestamp>.<MÉTODO>.<caminho>.<corpo>`, com janela de 300 segundos.

| Chamada | Quem chama | Segredo |
| - | - | - |
| `POST /api/v1/agent/actions` | Broker (`broker-consumer`) | `AGENT_ACTIONS_SECRET` |
| `GET /api/v1/agent/brands/<brand>/conversations/<conversation_id>/context` | Agente | `AGENT_CONTEXT_SECRET` |

- Cada chamada tem o seu segredo. O agente conhece só o segredo de leitura do contexto e não consegue forjar uma ação; o Broker conhece só o das ações.
- A assinatura cobre o método e o caminho com a query string: uma assinatura capturada não vale em outro endpoint nem em outra conversa.
- A assinatura é conferida antes de qualquer leitura do banco. Uma chamada sem assinatura válida não revela se a marca ou a conversa existem.

### Contexto da conversa

O endpoint de contexto devolve a conversa como o agente precisa vê-la para decidir:

| Campo | Conteúdo |
| - | - |
| `conversation` | `id`, `brand`, `channel`, `state` e `last_sequence` |
| `messages` | Histórico completo, em ordem crescente de `sequence`: autor, canal, texto e horário de cada mensagem |
| `customer_memory` | Resumo das conversas anteriores do lojista; nulo enquanto a memória não existe (F12) |

A marca fica no caminho. O RLS exige a marca na transação antes de qualquer linha ficar visível, e a marca no caminho entra no texto assinado: o acesso a uma conversa depende de conhecer a marca certa e de ter a assinatura certa. Conversa de outra marca, marca inexistente e identificador inválido respondem `404`.

O endpoint responde em qualquer estado da conversa. Quem decide se o evento ainda pede ação é o agente: se o contexto traz uma mensagem do lojista mais nova que a do evento recebido, o agente descarta o evento, porque o evento da mensagem mais nova produz a resposta.

A resposta é montada por `Agents::ConversationContext` a cada leitura, direto do banco, sem cache.

### Recebimento de uma ação

O corpo da chamada é a ação do agente, exatamente como ela está no Kafka. A marca e a conversa vêm desse corpo, que é assinado. O header `Idempotency-Key` leva a chave calculada pelo Broker, no formato `<inbound_event_id>:<type>`: o evento de entrada que motivou a ação e o tipo dela.

`Agents::ActionProcessor` trata a ação em uma sequência fixa:

1. **Formato.** O corpo segue o schema `action` do contrato, e a `Idempotency-Key` é a derivada do próprio corpo. Uma chave que não corresponde à ação seria uma forma de burlar a deduplicação, e é recusada.
2. **Marca e conversa.** A marca vem do slug do corpo; a conversa é lida dentro da marca e travada com `FOR UPDATE`.
3. **Repetição.** Se a chave já foi processada, o Core devolve o mesmo corpo e o mesmo código da primeira vez, sem novo efeito nem novo registro.
4. **Coerência.** O evento de entrada citado é uma mensagem da própria conversa, e o `based_on_sequence` não passa da última sequência dela. Uma ação que fala de mensagens inexistentes é recusada como inválida.
5. **Estado.** A conversa está com a IA (`with_ai`). Em qualquer outro estado, a ação é recusada com `rejected`.
6. **Atualidade.** Nenhuma mensagem do lojista é mais nova que o `based_on_sequence`. Se existe, a ação é recusada com `stale`.
7. **Execução.** O efeito da ação, o registro de auditoria dela e a chave processada são gravados na mesma transação.

**Por que travar a conversa.** A trava na linha da conversa faz com que as ações de uma mesma conversa sejam tratadas uma de cada vez. Duas cópias da mesma ação, chegando juntas, não produzem dois efeitos: a segunda espera a primeira terminar e, quando segue, encontra a chave já processada e devolve o mesmo resultado. No nível de isolamento `READ COMMITTED`, padrão do PostgreSQL, cada comando enxerga o que já estava confirmado no instante em que começou, e por isso a consulta da segunda cópia, feita depois da trava, enxerga o que a primeira gravou. A mesma trava serializa a ação com uma mensagem nova do lojista, que atualiza a mesma linha: a ação é avaliada com a conversa em um estado definido.

**Por que o estado vem antes da atualidade.** A conversa pode sair da IA sem mensagem nova do lojista, quando um analista assume ou quando ela é resolvida. Nesses casos a ação chega com a sequência em dia e mesmo assim não pode valer.

### Os quatro efeitos

| Ação | O que acontece |
| - | - |
| `reply` | A resposta é gravada como mensagem da IA, com o atendente da conversa, e a entrega ao lojista é enfileirada na mesma transação, pelo mesmo canal e pelo mesmo número ou e-mail da marca que recebeu a mensagem respondida |
| `escalate` | O Core grava o handoff com motivo, resumo e contexto estruturado (intenção, entidades, ferramentas e retornos, tentativas, sentimento, próximo passo sugerido e confiança). A conversa vai para `awaiting_human` na fila de escalação da fila em que estava, ou na mesma fila quando ela não tem fila de escalação, sem atendente e com o horário de entrada na espera (`Conversations::Escalate`) |
| `categorize` | A categoria informada pelo agente dispara um novo roteamento pelas regras da marca. Conforme a regra que casar, a conversa volta à IA, vai para uma fila humana ou fica em triagem |
| `resolve` | A conversa vai para `resolved`, com o horário de resolução, e o atendente continua registrado nela. Nenhuma mensagem vai ao lojista; se ele escrever dentro do prazo de reabertura, a conversa volta à triagem |

A mensagem respondida pelo `reply` é a última mensagem do lojista até o `based_on_sequence`. É dela que a entrega lê o destinatário, que só existe em mensagens do lojista.

Cada evento de entrada admite uma ação de cada tipo, porque a chave combina evento e tipo. O agente pode, por exemplo, reclassificar e responder ao mesmo evento. Se a reclassificação leva a conversa para um humano, a resposta seguinte é recusada com `rejected`, como deve ser.

### Respostas ao Broker

| Código | Status | Significado para o Broker |
| - | - | - |
| `200` | `accepted` | Ação aplicada; também a resposta da repetição |
| `409` | `stale` | A conversa avançou; resultado final, sem retry e sem DLQ |
| `409` | `rejected` | A conversa não está com a IA; resultado final, sem retry e sem DLQ |
| `400` | `missing_idempotency_key` | Chamada sem a chave |
| `401` | `invalid_signature`, `expired_timestamp` | Assinatura ausente, errada ou fora da janela |
| `404` | `not_found` | Marca ou conversa inexistente |
| `422` | `invalid_payload` | Ação fora do contrato ou incoerente com a conversa |

Os dois `409` são decisões de negócio, não falhas: reenviar não mudaria o resultado. A aceitação e as duas recusas ficam guardadas com a chave, e a repetição recebe sempre a mesma resposta. Os erros `400`, `401`, `404` e `422` não ficam guardados: uma ação corrigida com a mesma chave ainda pode ser aceita.

### Auditoria e linha do tempo

Toda ação tratada deixa um registro em `audit_events`:

| Situação | Evento |
| - | - |
| Ação aceita | `agent.reply`, `agent.escalate`, `agent.categorize` ou `agent.resolve` |
| Ação desatualizada | `agent.action.stale`, com a sequência usada pelo agente e a última do lojista |
| Conversa fora da IA | `agent.action.rejected`, com o estado da conversa |

O registro guarda o corpo completo da ação e a `Idempotency-Key`. O envelope do evento traz o horário em que o Core recebeu a chamada e o trace do header `traceparent`. Os efeitos de domínio, como a mensagem gravada, o handoff, a mudança de estado e o novo roteamento, têm os seus próprios eventos, gravados na mesma transação.

Com isso, a linha do tempo de uma resposta é montada só a partir da auditoria:

```text
Core recebe a mensagem (received_at do message.created)
  → Broker recebe o webhook (broker_received_at)
  → Kafka grava o evento (kafka_appended_at)
  → agente consome (agent_consumed_at) e consulta ferramentas (started_at, finished_at)
  → agente publica (agent_published_at)
  → Core recebe a ação (received_at do agent.<type>)
  → canal entrega a resposta (message.delivered)
```

O ator de todos esses eventos é a IA. Na recusa por estado, a conversa pode estar com um analista ou sem atendente; o registro atribui a tentativa ao atendente IA da marca, que é quem tentou agir.

## O que o sistema garante

- Uma ação entregue várias vezes produz um único efeito, e todas as entregas recebem a mesma resposta.
- Uma ação baseada em uma conversa que já recebeu mensagem nova do lojista não tem efeito.
- Uma ação sobre uma conversa que não está com a IA não tem efeito.
- Toda ação tratada, aceita ou recusada, deixa registro de auditoria; a repetição não deixa.
- Efeito, auditoria, entrega ao canal e registro da chave são gravados juntos ou não são gravados.
- Nenhuma chamada lê ou altera dados de uma marca diferente da sua.

## Como compõe os entregáveis do projeto

Esta parte fecha o caminho de volta do agente à plataforma. Sem ela, o Core avisa o agente de cada mensagem, mas nenhuma decisão da IA chega ao lojista. Cada entregável abaixo depende dela em algum ponto.

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Integração com o atendente por webhooks e broker | O lado do Core na volta: recebe a ação do Broker, aplica e responde conforme o contrato; e a leitura do contexto pelo agente | Webhook de ida (F7), Broker (F9) e agente mock (F10) |
| Interface de conversa entre cliente e atendente (IA) | A resposta da IA vira mensagem da conversa e chega ao lojista pelo canal em que ele escreveu, pelo mesmo caminho de saída do analista | Telas de conversa (F4 e F11) |
| Triagem, priorização e distribuição entre IA e analistas | A IA participa da triagem: o `categorize` reclassifica e dispara novo roteamento pelas regras da marca, e o `escalate` tira a conversa da IA e a coloca em espera por um humano | Classificador, regras e distribuição por capacidade (F6); fila de escalação e painel do analista (F11) |
| Handoff com resumo e contexto, preservando o histórico | O `escalate` grava o handoff com motivo, resumo e contexto estruturado, e o histórico continua na mesma conversa | Painel do analista e notificação (F11) |
| Rastreabilidade e auditoria das decisões | Cada ação, aceita ou recusada, tem registro próprio com o corpo completo, as ferramentas e os horários de cada salto | Linha do tempo na tela (F14) |
| Memória e contexto entre interações | O agente lê o histórico completo da conversa antes de cada decisão | Memória do lojista entre conversas (F12) |
| Agente mock com ferramentas falsas | A API registra as ferramentas consultadas e, quando a ação traz o campo `model`, o modelo, a versão e os parâmetros de cada decisão | Agente (F10) |
| Multi-marca | Toda leitura e ação acontece dentro da marca da conversa, com assinatura que inclui a marca no contexto | RLS e papéis de banco (F1) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H3 · nenhuma mensagem perdida nem duplicada com falhas | A deduplicação pela `Idempotency-Key` impede que reentregas causadas pelo reinício do Broker ou pela morte de um worker cheguem ao lojista. A recusa `stale` define quando uma mensagem do lojista conta como atendida: existe uma ação aceita com `based_on_sequence` maior ou igual à sequência dela, e essa é a regra da reconciliação |
| H4 · latência ponta a ponta com p95 < 1 s, descontada a latência do agente | O registro da ação guarda os horários de consumo e publicação do agente e de cada ferramenta, o que separa o tempo do agente do tempo da plataforma |
| H1 e H2 | Não dependem desta parte diretamente, mas a carga dela no `web` e a trava por conversa entram nas medidas (ver "Limitações") |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 5 · Modos de falha do agente mock | Dois dos quatro modos são tratados aqui. A **ação duplicada** produz um único efeito e recebe a mesma resposta; a **ação desatualizada** recebe `409 stale` e fica registrada. Os modos de atraso e sem resposta são tratados pela varredura do timeout do agente (F11). Com isso, a robustez pode ser demonstrada ligando um modo no agente e mostrando a resposta da API e o registro de auditoria |
| 1 · Briefing de handoff avaliado pelo analista | O `escalate` grava todo o conteúdo do briefing: problema resumido, intenção, entidades, ferramentas e retornos, tentativas, sentimento, próximo passo sugerido e confiança. O contrato recusa um `escalate` sem próximo passo ou sem confiança, o que garante que todo handoff tem esses campos. O cartão e a avaliação pelo analista são da F11 |
| 4 · "Por que caiu aqui?" | Quando o agente reclassifica a conversa, o novo roteamento grava a regra e a versão que casaram, com a indicação de que o gatilho foi o `categorize` da IA. A tela consegue explicar a fila atual mesmo quando ela é resultado de uma decisão do agente |
| 2 · Cockpit operacional | O motivo de cada escalação fica gravado no handoff e no registro da ação, e é o dado de origem do Pareto de motivos de escalação; o painel é da F14 |

## Limitações

- **Uma conversa de cada vez.** A trava serializa tudo o que acontece em uma conversa: ações do agente e mensagens do lojista. Conversas diferentes seguem em paralelo, mas uma conversa muito ativa forma fila. O efeito na carga é medido na F15.
- **Carga no `web`.** Cada mensagem do lojista gera duas chamadas a mais no processo `web`, a leitura do contexto e a ação; na meta de 250 msg/s, são cerca de 500 requisições por segundo. O contexto é montado do banco a cada leitura, e o cache fica para a F15, se a medida pedir.
- **Histórico inteiro.** O contexto traz todas as mensagens da conversa, sem paginação. O tamanho é limitado pelo ciclo de vida da conversa, que fecha depois do prazo de reabertura.
- **Escalação sem conferência de capacidade.** A conversa escalada vai para a fila de escalação da fila em que estava (`Conversations::Escalate`), com a prioridade que tinha e o SLA do destino, ou fica na mesma fila quando ela não tem fila de escalação. A capacidade do destino não é conferida; a contagem das conversas abertas e a capacidade ficam no `conversation.escalated`. O analista recebe o caso quando pede o próximo no painel (`Routing::Distributor.next_for`).
- **Memória do lojista.** `customer_memory` é sempre nulo; o resumo das conversas anteriores entra na F12.
- **Uma ação por tipo e evento.** A chave não distingue duas ações do mesmo tipo para o mesmo evento: a segunda é tratada como repetição da primeira.
- **Ordem das chaves.** O corpo guardado para a repetição fica em `jsonb`, que não preserva a ordem das chaves: a repetição traz o mesmo conteúdo com as chaves em outra ordem.
- **Horários de máquinas diferentes.** A linha do tempo compara horários carimbados por processos distintos e depende de os relógios estarem alinhados; no ambiente local, todos usam o relógio da mesma máquina.

## Operação

### Sem o Broker

A task `agent:` faz o papel do Broker e do agente, no contêiner `web`:

```text
bin/rails agent:context CONVERSATION=<id>
bin/rails agent:action CONVERSATION=<id> TYPE=reply TEXT="..."
bin/rails agent:action CONVERSATION=<id> TYPE=categorize CATEGORY=maquininha
bin/rails agent:action CONVERSATION=<id> TYPE=escalate [REASON=...] [SUMMARY=...]
bin/rails agent:action CONVERSATION=<id> TYPE=resolve [REASON=...]
```

A ação nasce da última mensagem do lojista; `BASED_ON` e `INBOUND_EVENT_ID` permitem simular uma ação atrasada. A mesma ação enviada de novo tem a mesma chave e recebe a mesma resposta. O endereço do Core é `CORE_URL`, com padrão `http://localhost:3000`.

### Configuração

`AGENT_ACTIONS_SECRET` e `AGENT_CONTEXT_SECRET` ficam no `.env` e chegam aos serviços Rails pelo bloco `rails-environment` do `compose.yaml`. São textos aleatórios gerados para o projeto, por exemplo com `openssl rand -hex 32`.

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/agents/action_processor_spec.rb` | Os quatro efeitos e seus eventos; repetição com um único efeito, inclusive com duas cópias simultâneas em transações reais; `stale` e `rejected` com auditoria e repetição sem novo registro; estado conferido antes da atualidade; recusas por formato e coerência; corpo, ferramentas, modelo e horários no registro da ação |
| `core/spec/modules/agents/conversation_context_spec.rb` | Contexto conforme o contrato, em ordem, e isolado por marca |
| `core/spec/requests/api/v1/agent/actions_spec.rb` | Códigos HTTP, assinatura, chave obrigatória, trace do header e respostas validadas pelo contrato |
| `core/spec/requests/api/v1/agent/contexts_spec.rb` | Assinatura com o segredo certo e a marca no caminho, recusa do segredo das ações, `404` entre marcas e corpo validado pelo contrato |
| `core/spec/contract/` e `agent_mock/tests/contract/` | Os mesmos schemas, exemplos e vetores de assinatura em Ruby e em Python |

No Compose, sem o Broker, uma mensagem de WhatsApp enviada pelo simulador recebe a resposta da IA pelo mesmo número; a repetição do `reply` não duplica a mensagem; uma ação atrasada recebe `409 stale`; depois de `resolve` ou `escalate`, uma nova ação recebe `409 rejected`; e a auditoria mostra cada passo.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Contrato (F3) | Define os corpos da ação, da resposta e do contexto, a assinatura e a `Idempotency-Key`; a API implementa o lado do Core |
| Canais (F4) | O `reply` sai pelo mesmo caminho de saída das respostas humanas e chega ao canal de origem |
| Roteamento (F6) | O `categorize` usa o mesmo ponto de entrada de roteamento da triagem |
| Saída para o Broker (F7) | O webhook leva a `context_url`; a conferência de estado antes do envio economiza trabalho do agente, e a recusa na API é a barreira final |
| Broker (F9) | Chama a API de ações com `AGENT_ACTIONS_SECRET` e trata os `409` como resultado final; os demais `4xx` vão para a DLQ |
| Agente mock (F10) | Lê o contexto com `AGENT_CONTEXT_SECRET` e devolve na ação os horários que recebeu e os seus |
| Handoff e painel (F11) | `Conversations::Escalate`, chamado pelo `escalate`, leva a conversa à fila de escalação; painel do analista |
| Memória (F12) | Preenche `customer_memory` no contexto |
| Observabilidade (F14) | Monta a linha do tempo por mensagem a partir dos registros das ações |
| Robustez e escala (F15) | Mede o efeito da trava e da leitura do contexto sem cache |

## Fontes

- `documents/arquitetura.md`, seções "Contrato com o agente", "Idempotência", "Ação sobre contexto desatualizado", "Ação com a conversa fora da IA", "Handoff com resumo e contexto" e "Auditoria e rastreabilidade"
- `documents/fases/04-contrato-de-integracao.md`, seções "Resposta da API de ações", "Contexto da conversa" e "Assinatura"
- `documents/fases/05-canais-de-entrada-e-identidade.md`, saída por `Conversations::Outbound.append!`
- `documents/fases/07-triagem-roteamento-e-distribuicao.md`, roteamento acionado por `categorize`
- [PostgreSQL 18 · Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html)
- [PostgreSQL 18 · Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html)

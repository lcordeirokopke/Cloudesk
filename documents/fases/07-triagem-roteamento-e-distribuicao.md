# Cloudesk · Triagem, roteamento e distribuição

## O que é

A triagem, o roteamento e a distribuição decidem quem atende cada conversa, com que urgência e em quanto tempo. Para cada conversa nova ou reaberta, o Core:

- **classifica** a mensagem: identifica o assunto (categoria) e se o caso é urgente;
- **roteia** a conversa: escolhe fila, prioridade e SLA pelas regras configuradas pela operação, e define se o primeiro atendimento é da IA ou de um analista;
- **distribui** os casos da fila humana: o analista puxa o próximo caso conforme a sua capacidade, e dois analistas nunca recebem o mesmo caso.

Cada decisão fica registrada na auditoria com o motivo: as palavras que levaram à categoria, a regra e a versão que definiram a fila, as filas visitadas no transbordo e quem assumiu o caso.

## Onde fica no fluxo

```text
Mensagem do lojista → Conversations::Intake (uma transação)
   │
   ├─ conversa em triage? ── Routing::Route
   │                          ├─ Classifier: categoria e urgência
   │                          ├─ Matcher: primeira regra que casa
   │                          ├─ fila, capacidade e transbordo
   │                          └─ atendente inicial
   │                               ├─ ai    → with_ai        → webhook ao Broker → agente
   │                               └─ human → awaiting_human → Distributor.next_for(analista)
   │
   └─ mensagem gravada (message.created)
```

O roteamento roda dentro da transação do `Conversations::Intake`, antes da gravação da mensagem. Quando a mensagem é gravada, a conversa já tem fila e atendente, e o webhook ao Broker é enfileirado só se ela ficou com a IA. O agente também pode pedir um novo roteamento pela ação `categorize`, que passa pelo mesmo ponto de entrada.

## Por que existe e que valor gera

**A IA como primeiro nível, sem esconder o humano.** A regra decide caso a caso se a conversa começa com a IA ou direto com um analista. A operação pode mandar para a IA o que ela resolve bem e para humanos o que exige pessoa desde o início, como o repasse de um lojista que não é de alto volume nas seeds.

**Filas editáveis sem deploy.** Filas e regras são dados no banco, não código. Uma nova regra, uma mudança de prioridade ou a desativação de uma regra valem na próxima conversa, sem reinício. Cada mudança gera uma nova versão imutável e um registro de auditoria com o que mudou.

**Explicação de cada decisão.** A auditoria guarda a regra e a versão que casaram, as palavras que definiram a categoria, a pontuação de cada categoria e a cadeia de transbordo. Para qualquer conversa é possível responder por que ela caiu naquela fila, mesmo depois que a regra mudou.

**Proteção contra sobrecarga.** Cada fila tem capacidade. Fila cheia transborda para a fila de transbordo configurada, e cada analista recebe casos só até a própria capacidade.

**Distribuição justa e sem conflito.** O analista recebe o caso de maior prioridade e, entre os de mesma prioridade, o que espera há mais tempo. Dois analistas pedindo casos ao mesmo tempo recebem casos diferentes, sem que um espere o outro.

**Multi-marca.** Regras, filas, palavras-chave e horários são de cada marca. InfinitePay e JIM têm categorias, idiomas e fusos próprios, e uma regra de uma marca não alcança conversas da outra.

## Como funciona

### Classificação

`Routing::Classifier` define a categoria e a urgência a partir do texto da mensagem; no e-mail, o assunto entra antes do corpo. As listas de palavras ficam em `core/config/routing/classifier.yml`, por marca e com uma `version`.

As categorias são as skills das equipes:

| Marca | Categorias |
| - | - |
| InfinitePay | `repasse`, `taxas`, `transacao`, `maquininha`, `app` |
| JIM | `payout`, `fees`, `transaction`, `card_reader`, `app` |

Como a decisão é tomada:

- **Normalização.** Texto e palavras passam pela mesma normalização: caixa baixa, sem acentos e com espaços únicos. "Não caiu", "NAO CAIU" e "nao   caiu" são o mesmo texto.
- **Palavra inteira.** Cada palavra ou expressão casa inteira: "repasse" não casa em "repassei", "app" não casa em "apps", "fee" não casa em "feedback".
- **Dois pesos.** Cada categoria tem `terms`, palavras próprias dela, com peso 2, e `context`, palavras que aparecem em vários assuntos ("venda", "pix", "payment"), com peso 1. Uma palavra genérica indica o assunto, mas não o decide sozinha.
- **Expressão mais longa.** Quando duas palavras casam no mesmo trecho do texto, conta só a mais longa. Em "cobrado duas vezes", a expressão de `transacao` fica com o trecho, e "cobrado", de `taxas`, não conta.
- **Pontuação.** A pontuação de uma categoria é a soma dos pesos das palavras que contam, cada palavra uma vez. Vence a maior pontuação; no empate, a primeira categoria do YAML. Sem nenhuma palavra, a categoria fica vazia, e a regra genérica atende.
- **Urgência.** `high` quando alguma palavra da lista de urgência casa ("urgente", "fraude", "conta bloqueada", "not me"); senão, `normal`.

| Texto | Pontuação | Categoria |
| - | - | - |
| "Fui cobrado de taxa na venda" | `taxas` 3 (taxa 2, cobrado 1), `transacao` 1 (venda) | `taxas` |
| "O cliente foi cobrado duas vezes" | `transacao` 3 (cliente 1, cobrado duas vezes 2) | `transacao` |
| "A taxa do repasse" | `repasse` 2, `taxas` 2 | `repasse`, pelo desempate |

As listas são sintéticas e estão na versão 2 nas duas marcas. Toda mudança nelas aumenta a `version` da marca e passa pelo corpus `core/spec/fixtures/routing/classifier_corpus.yml`, com 117 frases sintéticas e a categoria e urgência esperadas de cada uma: os modelos de mensagem e os assuntos de e-mail do simulador de canais, frases por categoria, frases sem categoria, armadilhas de limite de palavra e casos de urgência. No corpus, 2 frases empatam, e as duas são ambíguas de fato: "Tem mensalidade para usar a maquininha?" e "How much do you charge per transaction?".

**Por que palavras-chave.** O classificador é determinístico e explicável: a mesma mensagem dá sempre o mesmo resultado, e a auditoria mostra as palavras e a pontuação que o produziram. Ele roda na transação da entrada, sem chamada externa. A classificação fina fica com o agente, que pode corrigir a categoria pela ação `categorize`.

### Regras

Uma regra tem uma condição (`when`) e um resultado (`then`):

```json
{
  "name": "InfinitePay · Repasse · Alto volume",
  "position": 1,
  "when": { "brand": "infinitepay", "category": "repasse", "segment": "alto_tpv" },
  "then": { "queue": "ip-financeiro-prioritaria", "priority": 90, "sla_minutes": 15, "first_attendant": "ai" }
}
```

| Parte | Chave | Significado |
| - | - | - |
| `when` | `brand` | Slug da marca da regra |
| `when` | `channel`, `category`, `segment`, `language` | Canal da conversa, categoria do classificador, segmento e idioma do lojista |
| `when` | `priority` | Urgência do classificador (`high` ou `normal`) |
| `when` | `hours` | `business` ou `off_hours`, pelo horário comercial da equipe da fila de destino |
| `then` | `queue` | Obrigatória; nome de uma fila da marca |
| `then` | `priority` | Obrigatória; prioridade numérica da conversa |
| `then` | `sla_minutes` | Opcional; sem ela, vale o SLA da fila |
| `then` | `first_attendant` | Opcional, `ai` ou `human`; sem ela, vale o atendente inicial da fila |

- Cada chave do `when` precisa casar. Valor simples compara por igualdade, lista casa com qualquer item, e fato vazio não casa.
- As regras são avaliadas em ordem de `position` e, no empate, de `rule_id`. A primeira que casa define fila, prioridade e SLA.
- O horário comercial é conferido no `received_at` da mensagem, no fuso da equipe (`teams.business_hours`, com dias, início, fim e fuso IANA). Horário ausente ou inválido conta como fora do expediente.
- Uma regra com chave desconhecida, valor de tipo errado, fila inexistente ou `hours` sem equipe com horário válido é recusada na gravação.

Toda marca mantém uma **regra genérica** ativa, com `when` vazio ou só com a marca. Ela garante que toda conversa tem destino: uma gravação que deixaria a marca sem regra genérica ativa é recusada.

### Versões e cache

Cada versão de uma regra é uma linha imutável de `routing_rules`, com o mesmo `rule_id` e `version` crescente. Vale a maior versão de cada regra, e ela participa da avaliação só quando `active`. Uma versão desativada esconde as versões ativas anteriores da mesma regra.

As regras vigentes de cada marca ficam no Solid Cache, com a chave `routing/rules/<brand_id>/<maior id de routing_rules>`. Como os ids são UUID v7, toda gravação cria um id maior e muda a chave: a regra nova vale na próxima conversa, sem expiração nem limpeza de cache. As filas não ficam no cache; capacidade, SLA, atendente inicial e transbordo são lidos do banco a cada roteamento.

### Roteamento

`Routing::Route` é o ponto de entrada único do roteamento. Roda dentro do `Tenancy.with_brand` de quem chama, na marca da conversa, e grava cada decisão pelo `Audit::Command`.

| Gatilho | Quem chama | Estado de partida | Classificação |
| - | - | - | - |
| `intake` | `Conversations::Intake`, para conversa em `triage` | `triage` | Pelo `Classifier`, com o texto e o assunto |
| `categorize` | `Agents::ActionProcessor`, na ação `categorize` | `with_ai` | Categoria informada pelo agente; a conversa volta a `triage` e solta o atendente; a urgência é mantida |

Depois da classificação, o caminho é o mesmo:

1. **Regra.** A primeira regra que casa com os fatos da conversa: marca, canal, categoria, urgência, segmento e idioma do lojista e horário da mensagem.
2. **Fila e transbordo.** Conta as conversas abertas da fila (`with_ai`, `awaiting_human` e `with_human`). Se a contagem atinge a capacidade, segue para a `overflow_queue` e conta de novo, até uma fila com vaga ou o fim da cadeia; a conversa entra na última fila visitada. Um ciclo na cadeia também a encerra.
3. **Valores.** A prioridade vem sempre da regra. Sem transbordo, SLA e atendente inicial vêm da regra quando ela informa, e da fila quando não. Com transbordo, valem o SLA e o atendente inicial da fila que recebeu a conversa.
4. **Atribuição.** Atendente inicial `ai`: o atendente IA da marca e o estado `with_ai`. Atendente inicial `human`: o estado `awaiting_human`, sem atendente, com `queued_at` igual ao horário da mensagem.

Sem regra que case, ou com a fila da regra inexistente, a conversa fica em `triage` e o Core grava `conversation.unrouted`; a próxima mensagem do lojista tenta de novo. Com a regra genérica obrigatória e a fila conferida na gravação da regra, esse caso funciona como proteção.

A conversa reaberta (`resolved → triage`) é classificada e roteada de novo. Mensagens de conversas em outros estados não passam pelo roteamento: a conversa que já está com a IA ou com um analista não muda de fila a cada mensagem.

### Distribuição

`Routing::Distributor.next_for(analista)` entrega ao analista o próximo caso das filas da equipe dele, em uma transação na marca:

1. **Trava o analista** (`FOR UPDATE`): dois pedidos simultâneos do mesmo analista são tratados um de cada vez, e a capacidade não é ultrapassada.
2. **Confere a capacidade**: com tantas conversas `with_human` quanto a capacidade, o analista não recebe caso.
3. **Escolhe o caso**: a conversa `awaiting_human` das filas da equipe com maior prioridade e, no empate, a que espera há mais tempo, com `FOR UPDATE SKIP LOCKED`.
4. **Atribui**: a conversa vai para `with_human` com o analista, e o Core grava `conversation.assigned`.

**Por que `SKIP LOCKED`.** Com `FOR UPDATE` simples, dois analistas que pedem caso ao mesmo tempo disputariam a mesma conversa do topo da fila, e o segundo esperaria o primeiro terminar. Com `SKIP LOCKED`, o segundo pula a linha travada e pega a próxima: os dois recebem casos diferentes, sem espera e sem conflito. O índice parcial `index_conversations_awaiting_human`, só das conversas em espera, existe para essa busca.

Só analista humano com equipe recebe caso.

### Gravação de regras

`Routing::RulePublisher` é o único caminho de gravação das regras:

| Operação | Efeito |
| - | - |
| `create` | Versão 1 de uma regra nova, ativa salvo indicação contrária |
| `update` | Copia a maior versão, aplica as mudanças e grava a versão seguinte |
| `activate`, `deactivate` | `update` com `active` verdadeiro ou falso |

- A definição passa pela validação de `when` e `then`; atributo desconhecido ou operação que não muda nada são recusados.
- A gravação roda sob a trava consultiva de roteamento da marca (`Routing::RoutingLock`, `pg_advisory_xact_lock`): duas edições simultâneas da mesma marca são serializadas, e a segunda parte da versão gravada pela primeira. As edições de fila e de equipe do admin usam a mesma trava, porque conferem as regras antes de gravar.
- `expected_version`, opcional em `update`, `activate` e `deactivate`, é a versão lida por quem edita; quando a maior versão é outra, a operação levanta `Routing::RulePublisher::Stale` e nada é gravado.
- Antes do commit, a marca precisa ter uma regra genérica ativa; sem ela, nada é gravado.
- Cada operação grava `routing_rule.published` com a operação, a versão nova e o diff de cada atributo (valor anterior e novo). O autor é `operator`, com `actor_id` nulo; `operator_name`, opcional em todas as operações, vai ao payload quando informado. O admin informa o usuário do basic auth; as tasks de demonstração não informam.

### Auditoria

| Evento | Quando | O que registra |
| - | - | - |
| `conversation.classified` | Classificação pela entrada ou pelo agente | Categoria, urgência, gatilho; na entrada, as palavras que contaram, a pontuação por categoria e a versão das listas |
| `conversation.routed` | Conversa atribuída a uma fila | Regra e versão que casaram, fila, prioridade, SLA, atendente inicial, transbordo e cada fila visitada com as conversas contadas e a capacidade |
| `conversation.unrouted` | Nenhuma regra casou ou a fila da regra não existe | Motivo e, quando houver, a regra |
| `conversation.assigned` | Analista recebe o caso | Fila, prioridade e horário de entrada na espera |
| `routing_rule.published` | Regra criada, editada, ativada ou desativada | Operação, versão nova e diff |

O `conversation.routed` aponta para a linha exata da versão da regra (`routing_rule_id`) e guarda a versão no payload. A regra pode mudar depois; a explicação da decisão continua a mesma.

## O que o sistema garante

- Toda conversa nova ou reaberta é classificada e roteada na mesma transação da mensagem.
- O agente é acionado só quando o roteamento deixou a conversa com a IA.
- A primeira regra que casa, na ordem configurada, define fila, prioridade e SLA, e a decisão registra a regra e a versão.
- Toda marca tem uma regra genérica ativa, e toda conversa tem um destino.
- Uma mudança de regra vale na próxima conversa, sem deploy, e fica registrada com o diff.
- Dois analistas nunca recebem o mesmo caso, e nenhum analista recebe casos além da sua capacidade.
- Regras, filas e decisões de uma marca não alcançam conversas de outra.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Triagem, priorização e distribuição entre IA e analistas | Classificador, regras, prioridade, SLA, transbordo, escolha entre IA e humano e distribuição por capacidade com `SKIP LOCKED` | Painel em que o analista pede o próximo caso, com "Pegar próximo" (F11) |
| Múltiplas filas configuráveis e editáveis pela operação | Filas e regras como dados, por marca, equipe, categoria, segmento, canal, idioma, urgência e horário; gravação versionada e auditada | Telas do admin (F13) |
| Integração com o atendente por webhooks e broker | Define quando a conversa vai para a IA e, com isso, quando o webhook é enfileirado; atende a ação `categorize` com novo roteamento | Envio do webhook (F7), API de ações (F8) e Broker (F9) |
| Handoff com resumo e contexto | A fila humana e a distribuição pelas quais o analista recebe o caso | Ação `escalate` (F8); fila de escalação e painel do analista (F11) |
| Rastreabilidade e auditoria das decisões | Eventos de classificação, roteamento, atribuição e publicação de regra, com regra, versão, palavras e pontuações | Linha do tempo na tela (F14) |
| Multi-marca | Listas, regras, filas e fusos por marca, dentro do RLS | Banco e papéis (F1) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min sem acúmulo de backlog | O roteamento entra na transação de cada mensagem nova, com regras em cache e contagem por índice parcial. A capacidade das filas de IA define quantas conversas chegam ao agente |
| H2 · entrada → Kafka com p95 < 300 ms | O tempo do roteamento soma-se ao tempo da transação de entrada: leitura das regras, busca da fila, contagem das conversas abertas, busca do atendente IA e dois `audit_events` |
| H3 e H4 | Não dependem desta parte diretamente; a decisão de mandar a conversa à IA define quais mensagens entram na reconciliação e na medida ponta a ponta |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 3 · "Por que caiu aqui?" | É a base do diferencial. O `conversation.routed` grava a regra e a versão que definiram fila, prioridade e SLA, com a cadeia de transbordo, e o `conversation.classified` grava as palavras e a pontuação que definiram a categoria. A tela da conversa é da F11 |
| 2 · Cockpit operacional | Fila, prioridade, SLA, `queued_at` e a categoria de cada conversa são os dados de origem da profundidade por fila e dos casos em risco de SLA (F14) |

## Limitações

- **Classificador por palavras.** Não entende negação, ironia nem sinônimos fora da lista. Um texto sem nenhuma palavra cai na regra genérica, e empates seguem a ordem do YAML. A correção vem do agente, pela ação `categorize`.
- **Categoria do agente sem conferência.** A categoria informada no `categorize` é gravada como chega, sem conferência com as listas do classificador.
- **Capacidade da fila contada sem trava.** Duas entradas simultâneas podem contar a mesma vaga e passar a capacidade em poucas conversas. O número contado fica no `audit_event`.
- **Capacidade das filas de IA nas seeds.** As filas `ip-financeiro-prioritaria` e `jim-finance-priority` têm capacidade 20; cheias, transbordam para a fila humana, e a conversa não chega ao agente. O valor é sintético, de exemplo, e é revisto antes da carga.
- **Regras humanas nas seeds.** As regras de urgência e de repasse fora do alto volume levam a conversa direto a um analista, sem passar pelo agente nem pelo Kafka. Na carga, a fração de mensagens urgentes e de repasse define quanto do tráfego chega ao agente.
- **SLA de demonstração só na regra genérica.** O `panel:demo_sla` muda a regra genérica, que recebe só as conversas sem categoria, de lojista de baixo volume ou sem segmento e sem urgência.
- **Escalação sem conferência de capacidade.** A conversa escalada vai para a fila de escalação da fila em que estava (`queues.escalation_queue_id`), com a prioridade que tinha, ou fica na mesma fila quando ela não tem fila de escalação. A escalação não confere a capacidade do destino: a contagem das conversas abertas e a capacidade ficam no `conversation.escalated` (F11).
- **Atendente IA único.** O roteamento para a IA usa o atendente IA da marca, o primeiro por nome, e a capacidade dele não é aplicada. Sem atendente IA na marca, a mensagem não é gravada.
- **Autor das edições.** As edições do admin são atribuídas a `operator`, com o usuário do basic auth em `operator_name`. O login é simulado: todos os operadores compartilham as credenciais `ADMIN_USER` e `ADMIN_PASSWORD`, e o nome não é uma identidade verificada.
- **Distribuição só por pedido.** O analista recebe um caso quando pede o próximo no painel ("Pegar próximo", que chama `Routing::Distributor.next_for`, F11); não existe atribuição automática a analistas livres.

## Operação

### Configuração nas seeds

As seeds criam, por marca, duas equipes com horário comercial no fuso da marca, seis filas, treze regras ativas, um atendente IA, quatro analistas com capacidade 5 e 50 lojistas. O segmento de cada lojista é sorteado com peso: 50% baixo, 30% médio e 20% alto volume. O Faker usa a semente fixa `20_261_115`, e rodar as seeds de novo não duplica registros.

As regras usam a urgência, o segmento, a categoria, o canal e o horário comercial da equipe da fila de destino. Cada regra tem uma prioridade própria, e a genérica fica por último.

| Posição | Regra (InfinitePay / JIM) | Condição | Fila | Prioridade | SLA | Atendente inicial |
| - | - | - | - | - | - | - |
| 1 | Urgente · Alto volume / Urgent · High volume | urgência `high`, `alto_tpv` / `high_tpv` | `ip-urgente` / `jim-urgent` | 100 | 10 min | `human` |
| 2 | Urgente / Urgent | urgência `high` | `ip-urgente` / `jim-urgent` | 95 | 15 min | `human` |
| 3 | Repasse · Alto volume / Payout · High volume | `repasse` / `payout`, alto volume | `ip-financeiro-prioritaria` / `jim-finance-priority` | 90 | 15 min | `ai` |
| 4 | Transação · Alto volume / Transaction · High volume | `transacao` / `transaction`, alto volume | `ip-transacoes` / `jim-transactions` | 80 | 20 min | `ai` |
| 5 | Maquininha / Card reader | `maquininha` / `card_reader`, horário comercial | `ip-maquininha` / `jim-card-reader` | 65 | 45 min | `ai` |
| 6 | Transação / Transaction | `transacao` / `transaction` | `ip-transacoes` / `jim-transactions` | 60 | 45 min | `ai` |
| 7 | Maquininha · Fora do horário / Card reader · Off hours | `maquininha` / `card_reader`, fora do horário | `ip-maquininha` / `jim-card-reader` | 55 | 90 min | `ai` |
| 8 | Repasse / Payout | `repasse` / `payout` | `ip-financeiro` / `jim-finance` | 50 | 60 min | `human` |
| 9 | Taxas / Fees | `taxas` / `fees`, chat ou WhatsApp | `ip-suporte-geral` / `jim-general-support` | 35 | 90 min | `ai` |
| 10 | App | `app` | `ip-suporte-geral` / `jim-general-support` | 25 | 60 min | `ai` |
| 11 | Taxas · E-mail / Fees · Email | `taxas` / `fees`, e-mail | `ip-suporte-geral` / `jim-general-support` | 20 | 240 min | `ai` |
| 12 | Geral · Médio e alto volume / General · Mid and high volume | médio ou alto volume | `ip-suporte-geral` / `jim-general-support` | 15 | 120 min | `ai` |
| 13 | Geral / General | genérica | `ip-suporte-geral` / `jim-general-support` | 10 | 120 min | `ai` |

O nome completo de cada regra leva a marca na frente, por exemplo `InfinitePay · Urgente` e `JIM · Urgent`.

| Fila | Equipe | SLA | Capacidade | Atendente inicial | Transbordo | Escalação |
| - | - | - | - | - | - | - |
| `ip-financeiro` / `jim-finance` | Financeiro / Finance | 60 min | 50 | `human` | | |
| `ip-financeiro-prioritaria` / `jim-finance-priority` | Financeiro / Finance | 15 min | 20 | `ai` | `ip-financeiro` / `jim-finance` | `ip-financeiro` / `jim-finance` |
| `ip-urgente` / `jim-urgent` | Financeiro / Finance | 10 min | 15 | `human` | | |
| `ip-transacoes` / `jim-transactions` | Financeiro / Finance | 30 min | 60 | `ai` | | `ip-financeiro` / `jim-finance` |
| `ip-maquininha` / `jim-card-reader` | Suporte Técnico / Technical Support | 45 min | 60 | `ai` | | |
| `ip-suporte-geral` / `jim-general-support` | Suporte Técnico / Technical Support | 120 min | 100 | `ai` | | |

O teste `core/spec/seeds_spec.rb` passa uma combinação de fatos por regra pelo `Routing::Matcher`, com as regras gravadas pelas seeds, e confere a regra, a fila e a prioridade de cada uma.

### Reprodução da massa de dados

As seeds e o simulador usam sementes fixas: os mesmos comandos, em banco vazio, geram os mesmos lojistas, regras e textos. Os ids externos e os horários das mensagens são novos a cada execução, e as regras de maquininha dependem do horário comercial no momento do envio.

1. Banco de desenvolvimento vazio, criado pelo superusuário no contêiner `postgres`:
   `docker compose exec postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE \"$DB_DEVELOPMENT_NAME\" WITH (FORCE)" -c "CREATE DATABASE \"$DB_DEVELOPMENT_NAME\" OWNER \"$DB_OWNER_USERNAME\""'`
2. Schema e seeds com o papel dono:
   `docker compose exec web sh -c 'DB_USERNAME="$DB_OWNER_USERNAME" DB_PASSWORD="$DB_OWNER_PASSWORD" bin/rails db:migrate db:seed'`
3. Lojistas para o simulador: `docker compose exec web bin/rails simulator:personas`
4. Tráfego: `docker compose exec channel-simulator channel-simulator send --count 120 --rate 4 --urgency-ratio 0.15 --seed 1`

O banco de teste é recriado do mesmo jeito, com `DB_TEST_NAME` no passo 1 e `RAILS_ENV=test bin/rails db:migrate` no passo 2; o RSpec roda as seeds antes da suíte.

### Banco

| Coluna ou índice | Uso |
| - | - |
| `routing_rules.active` | A versão vigente participa da avaliação só quando ativa |
| `conversations.urgency` | Urgência do classificador (`high` ou `normal`) |
| `conversations.sla_minutes` | SLA definido pelo roteamento |
| `conversations.queued_at` | Horário de entrada na fila humana |
| `index_conversations_open_by_queue` | Contagem das conversas abertas da fila, para a capacidade |
| `index_conversations_awaiting_human` | Próximo caso da fila humana, por prioridade e tempo de espera |

As colunas e os índices vêm da migração `core/db/migrate/20261120120000_add_routing_columns.rb`.

### Arquivos principais

| Arquivo | Conteúdo |
| - | - |
| `core/config/routing/classifier.yml` | Palavras de categoria e de urgência por marca, com `version` |
| `core/app/modules/routing/classifier.rb` | Categoria, urgência, palavras que contam, pontuações e versão |
| `core/app/modules/routing/rule_definition.rb` | Validação de `when` e `then`; regra genérica |
| `core/app/modules/routing/compiled_rules.rb` | Regras vigentes em ordem, no Solid Cache |
| `core/app/modules/routing/matcher.rb` | Primeira regra que casa |
| `core/app/modules/routing/business_hours.rb` | Horário comercial da equipe, com fuso |
| `core/app/modules/routing/route.rb` | Ponto de entrada: classifica, aplica as regras, resolve o transbordo, atribui e audita |
| `core/app/modules/routing/distributor.rb` | Próximo caso do analista, com `SKIP LOCKED` |
| `core/app/modules/routing/rule_publisher.rb` | Criação, edição, ativação e desativação de regras, com versão, diff e auditoria |

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/modules/routing/classifier_spec.rb` | Normalização, palavra inteira, pesos, expressão mais longa, desempate, urgência, assunto do e-mail, listas por marca e um exemplo por frase do corpus |
| `core/spec/modules/routing/rule_definition_spec.rb` | Chaves e valores aceitos e recusados, fila da marca, `hours` e regra genérica |
| `core/spec/modules/routing/matcher_spec.rb` | Ordem de avaliação, todas as chaves, lista como "qualquer um", fato vazio, urgência e horário; com as regras do banco, só a maior versão e regra inativa ignorada |
| `core/spec/modules/routing/business_hours_spec.rb` | Dentro e fora do horário, limites, fuso, fim de semana e horário inválido |
| `core/spec/modules/routing/compiled_rules_spec.rb` | Ordem e forma, cache, chave por marca e mudança de chave na nova versão |
| `core/spec/modules/routing/route_spec.rb` | IA e humano, valores da regra e da fila, transbordo, cadeia e ciclo, eventos com regra e versão, `unrouted`, `categorize` e marca do bloco |
| `core/spec/modules/routing/distributor_spec.rb` | Ordem por prioridade e espera, filas da equipe, capacidade do analista, atendente IA recusado; dois analistas concorrentes e o mesmo analista em dois pedidos simultâneos, em transações reais |
| `core/spec/modules/routing/rule_publisher_spec.rb` | Versão 1, nova versão com diff, definição inválida, operação sem mudança, ativar e desativar, recusa sem regra genérica |
| `core/spec/modules/conversations/intake_spec.rb` | Roteamento na abertura e na reabertura, webhook só com a IA, regra genérica, assunto do e-mail, conversa fora de `triage` e duas marcas com o query cache ligado |

No Compose, mensagens do simulador nos três canais das duas marcas chegam roteadas. O repasse de lojista `alto_tpv` (`high_tpv` na JIM) cai na fila prioritária, com a IA e com o job de webhook; o repasse de outro segmento cai na fila financeira humana, sem webhook; as demais categorias e as mensagens sem categoria caem na regra genérica, com a IA. Cada conversa tem `conversation.classified` e `conversation.routed` com a regra e a versão.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco multi-marca (F1) | Entidades `Team`, `Routing::Queue`, `RoutingRule`, `Attendant` e os estados da conversa, com RLS |
| Núcleo transacional e auditoria (F2) | Toda decisão passa pelo `Audit::Command`, que liga o evento à versão da regra |
| Canais (F4) | O `Conversations::Intake` chama o roteamento para a conversa em `triage` e condiciona o webhook a `with_ai` |
| Simulador de canais (F5) | Os modelos de mensagem e os assuntos de e-mail fazem parte do corpus do classificador |
| Saída para o Broker (F7) | Envia o webhook das conversas que o roteamento deixou com a IA |
| API de ações (F8) | A ação `categorize` chama `Routing::Route` com a categoria do agente |
| Handoff e painel (F11) | Fila de escalação, painel que chama `Distributor.next_for` e tela "Por que caiu aqui?" |
| Admin (F13) | Edita regras pelo `Routing::RulePublisher` e filas, equipes e analistas por `Admin::QueueEditor`, `Admin::TeamEditor` e `Admin::AttendantEditor`; as opções do formulário de regra vêm de `Routing::Dimensions` |
| Observabilidade (F14) | Profundidade por fila, risco de SLA e linha do tempo a partir dos eventos de roteamento |
| Experimento (F18) | A capacidade das filas de IA é revista antes da carga |

## Fontes

- `documents/arquitetura.md`, seções "Filas configuráveis pela operação" e "Diferenciais"
- `documents/fases/02-banco-multi-marca-e-entidades.md`, máquina de estados da conversa
- [PostgreSQL · SELECT, cláusula de travamento (`FOR UPDATE`, `SKIP LOCKED`) e `DISTINCT ON`](https://www.postgresql.org/docs/current/sql-select.html)
- [PostgreSQL · Funções de trava consultiva (`pg_advisory_xact_lock`)](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS)
- [PostgreSQL · Índices parciais](https://www.postgresql.org/docs/current/indexes-partial.html)
- [Rails Guides · Caching with Rails (query cache e `Rails.cache`)](https://guides.rubyonrails.org/caching_with_rails.html)

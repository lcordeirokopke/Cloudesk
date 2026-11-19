# Cloudesk · F6 · Triagem, roteamento e distribuição

## Objetivo

A F6 decide fila, prioridade, SLA e atendente de cada conversa. Toda conversa em `triage` recebe categoria e urgência de um classificador por palavras-chave; as regras de roteamento, avaliadas em ordem, definem a fila e o atendente inicial; a conversa vai para a IA (`with_ai`) ou para a fila humana (`awaiting_human`). O analista puxa o próximo caso da fila humana por capacidade, com `SELECT … FOR UPDATE SKIP LOCKED`. Toda decisão gera `audit_event`, e o de roteamento grava a regra e a versão que casaram.

Este documento detalha cada decisão e a fonte que a sustenta. O resumo está em `documents/arquitetura.md`, que prevalece; a lista de entregas e o critério de pronto estão em `contexto/ordem-de-implementacao.md`.

## Resumo das decisões

| Tema | Decisão |
| - | - |
| Momento do roteamento | Síncrono, na transação do `Conversations::Intake`, quando a conversa está em `triage` (aberta ou reaberta). Ordem: conversa, classificação, regras, atribuição, mensagem. Mensagens de conversas fora de `triage` não são reclassificadas |
| Webhook ao Broker | A mensagem é sempre gravada; o `message.created` enfileira o webhook só quando a conversa está em `with_ai` |
| Categorias | As skills das equipes. InfinitePay: `repasse`, `taxas`, `transacao`, `maquininha`, `app`. JIM: `payout`, `fees`, `transaction`, `card_reader`, `app`. Sem palavra casada, a categoria fica vazia e a regra genérica atende |
| Palavras-chave | `core/config/routing/classifier.yml`, por marca, com `version`. Cada categoria tem `terms` (peso 2) e `context` (peso 1); no mesmo trecho do texto conta só a expressão mais longa; vence a maior pontuação. A versão, as palavras e as pontuações vão para o `audit_event` |
| Urgência | Pelo mesmo texto, com lista própria de palavras: `high` ou `normal`. A condição `priority` das regras compara com a urgência; a prioridade numérica da conversa vem do `then.priority` |
| Texto e idioma | Texto da mensagem; no e-mail, assunto e corpo. O idioma é o `contact.locale` |
| Condições `when` | `brand`, `channel`, `category`, `priority`, `segment`, `language`, `hours`. Valor simples compara por igualdade; lista casa com qualquer item; todas as chaves precisam casar. Chave desconhecida é recusada na gravação |
| Condição `hours` | `business` ou `off_hours`, conferida no `received_at` da mensagem contra o `business_hours` da equipe da fila de destino da regra |
| Resultado `then` | `queue` e `priority` obrigatórios; `sla_minutes` e `first_attendant` opcionais. Quando a regra informa, vale a regra; quando não, vale a fila |
| Ordem e versão | Avaliação por `position` e, no empate, por `rule_id`. Só a maior versão de cada regra participa |
| Ativação | `routing_rules.active`. Ativar e desativar gravam nova versão com auditoria |
| Regra genérica | A gravação que deixa a marca sem regra genérica ativa (`when` vazio ou só com `brand`) é recusada |
| Autor das edições | `actor_type: "operator"`, `actor_id` vazio enquanto o login não existe |
| Cache | Solid Cache com a chave `routing/rules/<brand_id>/<maior id de routing_rules>`. Filas são lidas do banco na hora |
| IA | Fila com atendente inicial `ai`: atendente IA da marca e `with_ai`. A capacidade do atendente IA não é aplicada |
| Humanos | Fila com atendente inicial `human`: `awaiting_human`, sem atendente. O analista puxa o próximo caso das filas da sua equipe |
| Capacidade da fila | Máximo de conversas abertas na fila, contado sem trava. Fila cheia transborda para a `overflow_queue`, seguindo a cadeia; no fim dela, a conversa entra na última fila. No transbordo valem o SLA e o atendente inicial da fila de transbordo |
| Novo roteamento | `Routing::Route.call(conversation:, trigger:, ...)`, com `trigger` `intake` ou `categorize`. No `categorize`, a categoria vem do agente |
| Eventos | `conversation.classified`, `conversation.routed`, `conversation.unrouted`, `conversation.assigned` e `routing_rule.published` |

## Arquivos

| Arquivo | Conteúdo |
| - | - |
| `core/db/migrate/20261120120000_add_routing_columns.rb` | `routing_rules.active`, `conversations.urgency`, `sla_minutes` e `queued_at`, e dois índices parciais |
| `core/config/routing/classifier.yml` | Palavras-chave de categoria (`terms` e `context`) e de urgência por marca, com `version` |
| `core/app/modules/routing/classifier.rb` | Texto para categoria, urgência, palavras que contam, pontuações e versão |
| `core/app/modules/routing/rule_definition.rb` | Validação de `when` e `then`; definição de regra genérica |
| `core/app/modules/routing/compiled_rules.rb` | Regras vigentes de uma marca, em ordem, no Solid Cache |
| `core/app/modules/routing/matcher.rb` | Primeira regra que casa com os fatos da conversa |
| `core/app/modules/routing/business_hours.rb` | Horário comercial de uma equipe, com fuso |
| `core/app/modules/routing/route.rb` | Ponto de entrada: classifica, aplica as regras, resolve o transbordo, atribui e audita |
| `core/app/modules/routing/distributor.rb` | O analista puxa o próximo caso, com `SKIP LOCKED` |
| `core/app/modules/routing/rule_publisher.rb` | Criar, editar, ativar e desativar regras, com versão, diff e auditoria |
| `core/app/modules/conversations/intake.rb` | Chama `Routing::Route` em `triage` e condiciona o webhook a `with_ai` |
| `core/app/modules/audit/command.rb` | `Change#routing_rule`: o bloco informa a versão de regra que gravou |
| `core/app/models/routing_rule.rb` | Escopos `latest_versions` e `current`; `generic?` |
| `core/app/models/conversation.rb` | `OPEN_STATES`, `URGENCIES` e validação da urgência |
| `core/db/seeds.rb` | Regras com `active: true` |

## Banco

A migração roda com o papel dono. As tabelas já têm as permissões do papel da aplicação, e nenhum `GRANT` é acrescentado.

| Coluna ou índice | Definição | Uso |
| - | - | - |
| `routing_rules.active` | `boolean NOT NULL DEFAULT true` | A versão vigente participa da avaliação só quando ativa |
| `conversations.urgency` | `string`, check `urgency IN ('high', 'normal')`, nulo permitido | Urgência dada pelo classificador |
| `conversations.sla_minutes` | `integer`, nulo permitido | SLA definido pelo roteamento |
| `conversations.queued_at` | `datetime`, nulo permitido | Horário em que a conversa entrou na fila humana |
| `index_conversations_open_by_queue` | `(brand_id, queue_id) WHERE state IN ('with_ai', 'awaiting_human', 'with_human')` | Contagem das conversas abertas da fila, para a capacidade |
| `index_conversations_awaiting_human` | `(brand_id, queue_id, priority DESC, queued_at) WHERE state = 'awaiting_human'` | Próximo caso da fila humana |

O `structure.sql` é regenerado pelo `db:migrate` com o papel dono, e o banco de teste é atualizado com `RAILS_ENV=test bin/rails db:migrate`.

## Classificador

`Routing::Classifier.call(brand:, text:, subject:)` devolve categoria, urgência, palavras que contam por categoria, pontuação por categoria, palavras de urgência casadas e versão das listas da marca.

- **Normalização:** caixa baixa, sem acentos (`ActiveSupport::Inflector.transliterate`) e espaços únicos. As palavras do YAML passam pela mesma normalização; "Não caiu", "NAO CAIU" e "nao   caiu" são o mesmo texto.
- **Casamento:** palavra ou expressão inteira, com limites de palavra. "repasse" não casa em "repassei"; "app" não casa em "apps"; "fee" não casa em "feedback".
- **Listas e pesos:** cada categoria tem `terms`, palavras e expressões próprias dela, com peso 2, e `context`, palavras comuns a vários assuntos ("venda", "pix", "sale", "payment"), com peso 1.
- **Sobreposição:** quando duas palavras casam no mesmo trecho do texto, conta só a mais longa; no mesmo tamanho, a de maior peso e, depois, a da primeira categoria do YAML. Em "cobrado duas vezes", a expressão de `transacao` fica com o trecho, e "cobrado", de `taxas`, não conta; em "card reader", "reader" não soma de novo.
- **Pontuação:** soma dos pesos das palavras que contam, cada palavra uma vez, mesmo casando em vários trechos.
- **Categoria:** a de maior pontuação; no empate, a primeira na ordem do YAML. Sem nenhuma palavra, vazia.
- **Urgência:** `high` quando alguma palavra de urgência casa; senão, `normal`.
- **E-mail:** o texto é o assunto seguido do corpo; o assunto vem do `Channels::InboundMessage`.
- **Leitura:** o YAML é lido uma vez por processo. Uma marca sem entrada no YAML levanta `KeyError`, e uma lista de categoria fora de `terms` e `context` também.

Exemplos de pontuação:

| Texto | Pontuação | Categoria |
| - | - | - |
| "Fui cobrado de taxa na venda" | `taxas` 3 (taxa 2, cobrado 1), `transacao` 1 (venda) | `taxas` |
| "O cliente foi cobrado duas vezes" | `transacao` 3 (cliente 1, cobrado duas vezes 2) | `transacao` |
| "Quando cai o repasse das vendas?" | `repasse` 4 (quando cai 2, repasse 2), `transacao` 1 (vendas) | `repasse` |
| "A taxa do repasse" | `repasse` 2, `taxas` 2 | `repasse`, pelo desempate |

### Listas

As listas são sintéticas, uma por marca, no idioma da marca, e ficam em `core/config/routing/classifier.yml` (versão 2 nas duas marcas):

| Categoria (InfinitePay / JIM) | `terms`, exemplos | `context` |
| - | - | - |
| `repasse` / `payout` | repasse, recebíveis, antecipação, saque, não caiu, quando cai, saldo a receber / payout, deposit, settlement, withdrawal, has not arrived, instant payout | dinheiro, saldo, depósito, conta bancária, banco / funds, transfer, balance, money, bank, arrive |
| `taxas` / `fees` | taxa, tarifa, mdr, taxa de antecipação, percentual, mensalidade, quanto vocês cobram / fee, rate, pricing, commission, processing fee, monthly fee, how much do you charge | juros, desconto, cobrado, cobrança, parcelado, crédito, débito / interest, charged, charge, installments, credit, debit, cost |
| `transacao` / `transaction` | transação, estorno, chargeback, contestação, cobrado duas vezes, cobrança duplicada, pagamento recusado, comprovante / transaction, refund, chargeback, dispute, charged twice, duplicate charge, declined, receipt | venda, pagamento, pix, compra, cliente, extrato, pendente / sale, payment, purchase, customer, statement, pending |
| `maquininha` / `card_reader` | maquininha, máquina, leitor de cartão, bobina, não liga, não conecta, erro de conexão, cartão não passa, bateria, carregador / card reader, terminal, won't turn on, connection error, bluetooth, pairing, battery, hold a charge, swipe | tela, conexão, sinal, wifi, chip, trocar / reader, device, screen, signal, wifi, replace |
| `app` / `app` | app, aplicativo, login, senha, esqueci a senha, não abre, não consigo entrar, código de verificação, biometria / app, application, login, sign in, password, keeps crashing, verification code, can't access, face id | travando, trava, atualização, celular, acesso / update, phone, access |
| urgência | urgente, com urgência, emergência, o mais rápido possível, bloqueada, conta bloqueada, fraude, golpe, clonado, roubaram, hackeada, não autorizada, não reconheço, não fui eu / urgent, asap, as soon as possible, emergency, blocked, locked out, frozen, fraud, scam, stolen, hacked, unauthorized, not me, don't recognize | |

Palavras de uso geral que aparecem em pedidos de outra categoria ficam em `context`: "atualização" e "update" ("alguma atualização do repasse?") e "trava" ("a maquininha trava") não puxam a mensagem para `app`.

### Corpus

`core/spec/fixtures/routing/classifier_corpus.yml` tem frases sintéticas com a categoria e a urgência esperadas, por marca: os 15 modelos do simulador de canais, os assuntos de e-mail do simulador, frases por categoria, frases sem categoria, armadilhas de limite de palavra e casos de urgência. O `classifier_spec.rb` gera um exemplo por frase. Toda mudança nas listas aumenta a `version` da marca e passa pelo corpus.

No corpus, 2 das 117 frases têm empate de pontuação, e as duas são ambíguas de fato: "Tem mensalidade para usar a maquininha?" (`taxas` e `maquininha`) e "How much do you charge per transaction?" (`fees` e `transaction`). As duas ficam com a primeira categoria do YAML.

## Regras

### Forma

```json
{
  "name": "InfinitePay · Repasse · Alto volume",
  "position": 1,
  "when": { "brand": "infinitepay", "category": "repasse", "segment": "alto_tpv" },
  "then": { "queue": "ip-financeiro-prioritaria", "priority": 90, "sla_minutes": 15, "first_attendant": "ai" }
}
```

`Routing::RuleDefinition` valida uma regra na marca do bloco `Tenancy.with_brand` corrente:

| Parte | Chave | Regra |
| - | - | - |
| `when` | `brand` | Slug da marca da regra |
| `when` | `channel`, `category`, `segment`, `language` | Texto ou lista de textos |
| `when` | `priority` | Texto ou lista de textos; compara com a urgência (`high`, `normal`) |
| `when` | `hours` | `business` ou `off_hours`; exige fila de destino com equipe e horário comercial válido |
| `then` | `queue` | Obrigatória; nome de uma fila da marca |
| `then` | `priority` | Obrigatória; inteiro |
| `then` | `sla_minutes` | Opcional; inteiro positivo |
| `then` | `first_attendant` | Opcional; `ai` ou `human` |

Chaves desconhecidas, em `when` ou em `then`, são recusadas. A regra genérica tem `when` vazio ou só com `brand`.

### Versões vigentes

Cada versão é uma linha imutável de `routing_rules`; `rule_id` é igual entre as versões da mesma regra.

- `RoutingRule.latest_versions`: a maior versão de cada regra, com `DISTINCT ON (rule_id) … ORDER BY rule_id, version DESC`.
- `RoutingRule.current`: as versões de `latest_versions` com `active`. O filtro vem depois da escolha da versão: uma versão desativada esconde as versões ativas anteriores da mesma regra.

### Avaliação

`Routing::Matcher` recebe as regras e os fatos da conversa e devolve a primeira regra que casa:

| Fato | Origem |
| - | - |
| `brand` | Slug da marca |
| `channel` | Canal da conversa |
| `category` | Categoria da conversa |
| `priority` | Urgência da conversa |
| `segment` | `contact.segment` |
| `language` | `contact.locale` |
| `received_at` | Horário da mensagem, para `hours` |

- As regras são ordenadas por `position` e, no empate, por `rule_id`.
- Cada chave do `when` precisa casar. Valor simples compara por igualdade; lista casa com qualquer item. Fato vazio não casa.
- `hours` lê o `business_hours` da equipe da fila de destino da regra. Horário ausente ou inválido conta como `off_hours`.

### Horário comercial

`Routing::BusinessHours` lê `teams.business_hours`:

| Campo | Formato |
| - | - |
| `weekdays` | Dias ISO, de 1 (segunda) a 7 (domingo) |
| `from`, `to` | `HH:MM`; o início está dentro, o fim fora; `from` menor que `to` |
| `timezone` | Nome IANA, por exemplo `America/Sao_Paulo` |

O horário é conferido no fuso da equipe. Um horário incompleto ou inválido não tem instante comercial.

### Cache

`Routing::CompiledRules.for(brand)` devolve as regras vigentes em ordem, como hashes com `id`, `rule_id`, `version`, `name`, `position`, `when` e `then`, guardados no Solid Cache com a chave `routing/rules/<brand_id>/<maior id de routing_rules>`.

- O id é UUID v7: toda gravação de regra, inclusive ativar e desativar, cria uma linha com id maior que os anteriores, e a chave muda. A versão nova passa a valer na próxima conversa, sem expiração e sem limpeza do cache.
- O maior id é lido na marca corrente, com o RLS; cada marca tem a sua chave.
- As filas não ficam no cache: a capacidade, o SLA, o atendente inicial e a fila de transbordo são lidos do banco a cada roteamento.
- O ambiente de teste usa `null_store`; o teste do cache troca o store por um `MemoryStore`.

## Roteamento

`Routing::Route.call(conversation:, trigger:, text:, subject:, category:, actor_id:, received_at:)` roda dentro do `Tenancy.with_brand` de quem chama, na marca da conversa; fora dele, levanta `ArgumentError`. Cada decisão passa por `Audit::Command`.

| Passo | `trigger: "intake"` | `trigger: "categorize"` |
| - | - | - |
| Estado de partida | `triage` | `with_ai` |
| Classificação | `Classifier` pelo texto e assunto; grava categoria e urgência | Categoria do agente; a conversa vai para `triage` e solta o atendente; a urgência fica |
| Ator do `conversation.classified` | `system` | `ai`, com o atendente da conversa |

Depois da classificação, os passos são os mesmos:

1. **Regra:** `Matcher` com as regras de `CompiledRules` e os fatos da conversa. Sem regra, `conversation.unrouted` e a conversa fica em `triage`.
2. **Fila:** a fila da regra, pelo nome. Fila inexistente gera `conversation.unrouted`, com a regra, e a conversa fica em `triage`.
3. **Capacidade e transbordo:** conta as conversas da fila em `with_ai`, `awaiting_human` ou `with_human`, sem trava. Se a contagem atinge a capacidade, segue a `overflow_queue` e conta de novo. A cadeia termina na primeira fila com vaga, na fila sem transbordo ou na fila cujo transbordo já foi visitado; a conversa entra na última fila visitada.
4. **Valores:** prioridade do `then.priority`. Sem transbordo, SLA e atendente inicial da regra quando ela informa, senão da fila. Com transbordo, SLA e atendente inicial da fila que recebe a conversa.
5. **Atribuição:** `ai` leva ao atendente IA da marca (o primeiro por nome) e a `with_ai`, com `queued_at` vazio. `human` leva a `awaiting_human`, sem atendente, com `queued_at` igual ao `received_at`.
6. **Auditoria:** `conversation.routed`, com `routing_rule_id` e `rule_version` da versão que casou.

O `trigger` aceita `intake` e `categorize`; outro valor levanta `ArgumentError`.

### Integração com o Intake

O `Conversations::Intake`, na mesma transação da mensagem:

1. abre, reabre ou usa a conversa do lojista;
2. com a conversa em `triage`, chama `Routing::Route` com `trigger: "intake"`, o texto da mensagem, o assunto do e-mail e o `received_at`;
3. grava a mensagem com `message.created` e `webhook: conversation.state == "with_ai"`.

A conversa reaberta (`resolved → triage`) é classificada e roteada de novo. Uma conversa que fica em `triage` por `conversation.unrouted` é roteada de novo na próxima mensagem. Mensagens de conversas em outros estados não passam pelo roteamento.

## Distribuição

`Routing::Distributor.next_for(attendant)` roda em uma transação na marca do analista e devolve a conversa atribuída, ou `nil`:

1. trava a linha do analista com `FOR UPDATE`: pedidos simultâneos do mesmo analista esperam um pelo outro;
2. conta as conversas `with_human` do analista; na capacidade, devolve `nil`;
3. seleciona uma conversa `awaiting_human` das filas da equipe do analista, por `priority DESC, queued_at, id`, com `FOR UPDATE SKIP LOCKED LIMIT 1`: a conversa travada por outro analista é pulada;
4. passa a conversa para `with_human` com o analista e grava `conversation.assigned`.

Só analista humano com equipe recebe caso; outro atendente levanta `ArgumentError`.

## Gravação de regras

`Routing::RulePublisher` grava as regras; cada operação grava uma nova versão e `routing_rule.published`:

| Operação | Efeito |
| - | - |
| `create(brand:, attributes:)` | Versão 1 de uma regra nova, ativa salvo `active: false` |
| `update(brand:, rule_id:, attributes:)` | Copia a maior versão, aplica as mudanças e grava `version + 1` |
| `activate(brand:, rule_id:)` | `update` com `active: true` |
| `deactivate(brand:, rule_id:)` | `update` com `active: false` |

- `attributes` aceita `name`, `position`, `when`, `then` e `active`; outra chave levanta `ArgumentError`.
- `when` e `then` passam por `RuleDefinition`; definição inválida levanta `Routing::RuleDefinition::Invalid`.
- A operação que não muda a regra levanta `Routing::RulePublisher::Unchanged`.
- A gravação roda sob `pg_advisory_xact_lock` da marca: duas operações simultâneas da mesma marca são serializadas, e a segunda lê a versão gravada pela primeira.
- Antes do commit, a marca precisa ter uma regra genérica ativa entre as vigentes. Sem ela, levanta `Routing::RulePublisher::NoGenericRule` e a transação é desfeita.
- O índice único `(brand_id, rule_id, version)` recusa duas linhas com a mesma versão da mesma regra.

O `audit_event` aponta para a versão nova pelo `Change#routing_rule` do `Audit::Command`: o bloco informa a versão que gravou, e ela vale no lugar da informada na chamada.

## Eventos de auditoria

| Evento | Ator | Regra e versão | Antes e depois | Payload |
| - | - | - | - | - |
| `conversation.classified` | `system` (intake) ou `ai` (categorize) | Não | Intake: categoria e urgência. Categorize: estado, atendente e categoria | `trigger`, `category`, `urgency`; no intake, `matches` (palavras que contam por categoria e de urgência), `scores` (pontuação por categoria) e `classifier_version` |
| `conversation.routed` | `system` | Sim | Estado, fila, atendente, prioridade, SLA e `queued_at` | `trigger`, `rule` (id, `rule_id`, versão, nome, posição), `queue`, `priority`, `sla_minutes`, `first_attendant`, `attendant_id`, `overflow`, `queue_chain` (fila, conversas abertas contadas e capacidade de cada fila visitada) |
| `conversation.unrouted` | `system` | Quando a regra casou e a fila não existe | Estado | `trigger`, `reason` e, quando há, `rule` |
| `conversation.assigned` | `analyst` | Não | Estado e atendente | `queue_id`, `priority`, `queued_at` |
| `routing_rule.published` | `operator`, `actor_id` vazio | Sim, a versão nova | Atributos da regra | `operation`, `rule_id`, `version`, `diff` (atributo, valor anterior e novo) |

O `conversation.routed` é a base do diferencial "Por que caiu aqui?": a regra e a versão que definiram fila, prioridade e SLA ficam no `audit_event` desde a primeira decisão.

## Seeds

As regras das seeds são gravadas com `active: true`. Rodar `bin/rails db:seed` duas vezes mantém três regras ativas por marca, 50 lojistas e 5 atendentes.

| Marca | Regra | Posição | Condição | Fila | Atendente inicial |
| - | - | - | - | - | - |
| InfinitePay | InfinitePay · Repasse · Alto volume | 1 | `repasse`, `alto_tpv` | `ip-financeiro-prioritaria` | `ai` |
| InfinitePay | InfinitePay · Repasse | 2 | `repasse` | `ip-financeiro` | `human` |
| InfinitePay | InfinitePay · Geral | 3 | genérica | `ip-suporte-geral` | `ai` |
| JIM | JIM · Payout · High volume | 1 | `payout`, `high_tpv` | `jim-finance-priority` | `ai` |
| JIM | JIM · Payout | 2 | `payout` | `jim-finance` | `human` |
| JIM | JIM · General | 3 | genérica | `jim-general-support` | `ai` |

## Testes

| Arquivo | Cobertura |
| - | - |
| `spec/modules/routing/classifier_spec.rb` | Categoria, palavras e pontuação, caixa, acentos e espaços, palavra inteira, pesos de `terms` e `context`, expressão mais longa no mesmo trecho, palavra contada uma vez, empate, sem categoria, urgência, assunto do e-mail, listas por marca; um exemplo por frase do corpus |
| `spec/modules/routing/rule_definition_spec.rb` | Chaves aceitas e recusadas, tipos dos valores, marca, `hours`, fila inexistente ou de outra marca, `then` incompleto, `hours` com fila sem equipe ou sem horário, regra genérica |
| `spec/modules/routing/matcher_spec.rb` | Ordem por `position`, empate por `rule_id`, todas as chaves, lista como "qualquer um", fato vazio, `priority` como urgência, `hours`; com as regras do banco: seeds em ordem, só a maior versão, regra inativa ignorada |
| `spec/modules/routing/business_hours_spec.rb` | Dentro e fora do horário, limites, fuso, fim de semana, horário inválido |
| `spec/modules/routing/compiled_rules_spec.rb` | Ordem e forma, cache preenchido, chave por marca, nova versão muda a chave |
| `spec/modules/routing/route_spec.rb` | IA e humano, valores da regra e da fila, transbordo, contagem por estado, cadeia, ciclo, `conversation.classified`, `conversation.routed` com regra e versão, versão 2, `conversation.unrouted`, `categorize`, trigger desconhecido, marca do bloco |
| `spec/modules/routing/distributor_spec.rb` | Ordem por prioridade e tempo na fila, `conversation.assigned`, filas da equipe, capacidade do analista, atendente IA recusado; dois analistas concorrentes e o mesmo analista em dois pedidos simultâneos |
| `spec/modules/routing/rule_publisher_spec.rb` | Versão 1, nova versão com diff e autor, definição inválida, atributo desconhecido, operação sem mudança, regra inexistente, desativar e reativar, recusa sem regra genérica, segunda genérica |
| `spec/modules/conversations/intake_spec.rb` | Roteamento na abertura e na reabertura, fila prioritária com webhook, fila humana sem webhook, regra genérica, assunto do e-mail, conversa fora de `triage`, duas marcas com o query cache ligado |

- Os testes concorrentes do `Distributor` rodam fora da transação do RSpec, com threads e conexões próprias. Cada thread mantém a transação aberta depois de puxar os casos, e as conversas atribuídas ficam travadas enquanto a outra procura. A limpeza (`purge_conversations`, em `spec/support/database_roles.rb`) roda com o papel dono e desliga o trigger de `audit_events` só durante a limpeza, na mesma transação.
- `spec/support/channels.rb` tem `seed_contact_in_segment`, que escolhe o lojista das seeds pelo segmento, e `resolve_conversation`, que leva a conversa a `resolved` a partir do estado em que o roteamento a deixou.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`:

- testes cobrem a ordem de avaliação das regras: `matcher_spec.rb`;
- um teste concorrente prova que dois atendentes nunca recebem o mesmo caso: `distributor_spec.rb`;
- a decisão de roteamento registra regra e versão no `audit_event`: `route_spec.rb`.

O caminho também roda no Compose: mensagens do simulador nos três canais das duas marcas chegam roteadas. O repasse de lojista `alto_tpv` (`high_tpv` na JIM) cai na fila prioritária, em `with_ai`, com o job de webhook; o repasse de outro segmento cai na fila financeira humana, em `awaiting_human`, sem job de webhook; as demais categorias e as mensagens sem categoria caem na regra genérica. Cada conversa tem `conversation.classified` e `conversation.routed` com a regra e a versão.

## Pontos de atenção

- **Atendente IA da marca.** O roteamento para a IA usa o atendente `ai` da marca, o primeiro por nome. Sem nenhum, levanta `Routing::Route::Error` e a mensagem não é gravada.
- **`conversation.unrouted`.** Com a regra genérica obrigatória, ocorre só quando a fila apontada pela regra não existe. Fica como proteção.
- **Capacidade contada sem trava.** Duas entradas simultâneas podem contar a mesma vaga e passar a capacidade da fila em poucas conversas. O número contado fica no `audit_event`.
- **Capacidade 20 nas seeds.** As filas de IA prioritárias têm capacidade 20: cheias, transbordam para a fila humana e a conversa não chega ao agente. É o ponto em aberto 7 da ordem de implementação, para a F17.
- **Categoria do `categorize`.** A categoria informada pelo agente é gravada como chega, sem conferência com as listas do classificador.
- **Latência da entrada.** O roteamento acrescenta à transação do Intake a leitura das regras (cache), a busca da fila, a contagem das conversas abertas (índice parcial), a busca do atendente IA e dois `audit_events`.
- **Query cache entre marcas.** O Rails liga o query cache em requisições e jobs, e a chave do cache é o SQL, sem a marca. Uma requisição do WhatsApp pode trazer mensagens das duas marcas; as escritas do Intake da primeira marca limpam o cache antes das leituras da segunda. O `intake_spec.rb` cobre esse caso.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F8 | A ação `categorize` dispara novo roteamento | Chama `Routing::Route` com `trigger: "categorize"`, a categoria e o atendente IA como `actor_id`, dentro do `Tenancy.with_brand` da ação |
| F11 | A escalação usa a regra de escalação | Acrescenta o trigger `escalate` ao `Routing::Route`; o analista assume o caso por `Routing::Distributor.next_for`; a tela "Por que caiu aqui?" lê o `conversation.routed` |
| F13 | O admin edita regras e filas | As regras passam por `Routing::RulePublisher`, com o `actor_id` do operador; as filas são lidas do banco a cada roteamento |
| F17 | A capacidade das filas de IA limita a entrada no agente | A capacidade das seeds é revista antes da carga (ponto em aberto 7) |

## Fontes

- [PostgreSQL · SELECT, cláusula de travamento (`FOR UPDATE`, `SKIP LOCKED`) e `DISTINCT ON`](https://www.postgresql.org/docs/current/sql-select.html)
- [PostgreSQL · Funções de trava consultiva (`pg_advisory_xact_lock`)](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS)
- [PostgreSQL · Índices parciais](https://www.postgresql.org/docs/current/indexes-partial.html)
- [Rails Guides · Caching with Rails (query cache e `Rails.cache`)](https://guides.rubyonrails.org/caching_with_rails.html)
- `documents/arquitetura.md`, seção "Filas configuráveis pela operação"
- `documents/fases/02-banco-multi-marca-e-entidades.md`, máquina de estados da conversa

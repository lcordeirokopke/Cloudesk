# Cloudesk · Admin de filas e regras

## O que é

O admin é a área em que a operação cria e edita, por marca, as filas, as equipes, os analistas humanos e as regras de roteamento, sem deploy. Fica em `/admin` (`core/app/controllers/admin/`, layout `admin`), atrás de HTTP basic auth.

Filas e regras são dados no banco. Uma regra editada vira uma nova versão imutável e passa a valer no próximo roteamento; cada edição grava um `audit_event` com o operador, o diff e o horário.

## Onde fica no fluxo

```text
Operador → /admin (basic auth, marca na sessão)
  ├─ regras:                       Admin::RuleForm → Routing::RulePublisher → routing_rules (nova versão) + routing_rule.published
  └─ filas, equipes e analistas:   Admin::QueueEditor, Admin::TeamEditor, Admin::AttendantEditor → Audit::Command → <registro>.created/.updated

Próxima mensagem → Conversations::Intake → Routing::Route → Routing::CompiledRules (chave nova no Solid Cache) → fila, prioridade e SLA da regra
```

O admin escreve; o roteamento (`Routing::Route`, F6) lê as regras vigentes e as filas a cada conversa em `triage`.

## Por que existe e que valor gera

**Filas configuráveis pela operação.** O enunciado (TAPI) pede filas configuráveis e editáveis pela operação, por marca, equipe, categoria ou prioridade. O admin entrega isso sem deploy: a operação muda destino, prioridade, SLA, atendente inicial, capacidade e transbordo pela tela.

**Toda decisão auditada.** Cada versão de regra fica gravada para sempre, e cada edição grava o `audit_event` com o operador, o antes, o depois e o diff. O `conversation.routed` registra a regra e a versão que casaram, e o "Por que caiu aqui?" do painel mostra a versão que definiu a fila de cada conversa.

**Edição segura.** A edição confere a versão lida, recusa a gravação que deixaria o roteamento inconsistente (fila renomeada ainda citada por regra, marca sem regra genérica, horário comercial ausente para regra de horário) e serializa as gravações da marca. Nenhum registro referenciado é apagado.

## Como funciona

### Acesso e marca

`Admin::BaseController` exige HTTP basic auth com `ADMIN_USER` e `ADMIN_PASSWORD`; sem os dois preenchidos, o acesso é negado (`401`). O login é simulado:

- a tela inicial (`GET /admin`) lista as marcas, e `POST /admin/session` grava a escolhida em `session[:admin_brand]`; `DELETE /admin/session` a limpa;
- sem marca na sessão, as páginas internas voltam à escolha;
- toda leitura e escrita roda em `Tenancy.with_brand` da marca da sessão: registro de outra marca responde `404`;
- o usuário do basic auth é o `operator_name` gravado no payload dos eventos de edição, com `actor_type` `operator` e `actor_id` nulo.

### Telas

| Recurso | Rotas | O que mostra |
| - | - | - |
| Regras | `index`, `show`, `new`, `create`, `edit`, `update`, `activate`, `deactivate` (`/admin/rules/:rule_id`) | Lista na maior versão de cada regra, ativa ou não, em ordem de avaliação; tela com a versão vigente, todas as versões e o diff de cada uma |
| Filas | `index`, `show`, `new`, `create`, `edit`, `update` | Equipe, SLA, capacidade, atendente inicial, transbordo e fila de escalação; histórico de edições |
| Equipes | idem | Habilidades e horário comercial; histórico de edições |
| Atendentes | idem | Analistas humanos editáveis e o atendente IA só para leitura; histórico de edições |

Não existe rota de exclusão. Regras são ativadas e desativadas; filas, equipes e analistas são criados e editados. Os horários aparecem em UTC.

### Regras

As regras são gravadas só pelo `Routing::RulePublisher`, em um `Tenancy.with_brand`, sob a trava consultiva da marca (`Routing::RoutingLock`, `pg_advisory_xact_lock`):

| Operação | Efeito |
| - | - |
| `create` | Versão 1 de uma regra nova, ativa |
| `update` | Copia a maior versão, aplica as mudanças e grava `version + 1` |
| `activate`, `deactivate` | `update` com `active` `true` ou `false` |

Cada operação grava uma linha nova e imutável em `routing_rules` e o `routing_rule.published`, com `before`, `after` e payload com `operation`, `rule_id`, `version`, `diff` e `operator_name`. Antes de gravar, `Routing::RuleDefinition` confere o `when` e o `then`:

- `when`: chaves `brand`, `channel`, `category`, `priority`, `segment`, `language` e `hours`, cada uma com um texto ou uma lista de textos; `brand` é o slug da marca; `hours` é `business` ou `off_hours` e exige fila de destino com equipe e horário comercial válido;
- `then`: `queue` (nome de fila da marca) e `priority` (inteiro) obrigatórios; `sla_minutes` (inteiro positivo) e `first_attendant` (`ai` ou `human`) opcionais.

A operação é recusada, sem gravar nada, quando:

| Recusa | Exceção |
| - | - |
| Definição inválida | `Routing::RuleDefinition::Invalid` |
| A marca ficaria sem regra genérica ativa (`when` vazio ou só com `brand`) | `Routing::RulePublisher::NoGenericRule` |
| A operação não muda a regra | `Routing::RulePublisher::Unchanged` |
| A versão lida (`expected_version`) difere da maior versão | `Routing::RulePublisher::Stale` |

No admin, as recusas voltam ao formulário com `422` e a mensagem, ou à tela da regra com o aviso, no caso de ativar e desativar.

A regra vigente de cada `rule_id` é a maior versão com `active`. As regras vigentes, em ordem de avaliação (`position` e, no empate, `rule_id`), ficam no Solid Cache (`Routing::CompiledRules`) com a chave `routing/rules/<brand_id>/<maior id de routing_rules>`. Toda versão nova cria uma linha com id UUID v7 maior, a chave muda e a próxima conversa já lê as regras novas.

### Formulário de regra

`Admin::RuleForm` converte o formulário estruturado nos atributos do `Routing::RulePublisher`:

- uma caixa por valor de cada dimensão do `when` (`channel`, `category`, `priority`, `segment`, `language`): uma opção marcada vira texto, mais de uma vira lista e nenhuma tira a chave;
- `hours` como opção única: vazio (sem condição), `business` ou `off_hours`;
- `when.brand` é sempre o slug da marca da sessão;
- `then` com fila, prioridade, SLA e atendente inicial; SLA vazio e atendente "da fila" tiram a chave, e o roteamento usa o valor da fila;
- `position` e `priority` viram inteiros quando são números; o texto que não é número segue para a validação recusar.

As opções vêm de `Routing::Dimensions`: canais de `ContactIdentity::CHANNELS`, categorias do classificador (`core/config/routing/classifier.yml`), urgências `high` e `normal`, segmentos e idiomas por marca de `core/config/routing/dimensions.yml` (os mesmos que as seeds sorteiam) e horários de `Routing::RuleDefinition::HOURS`. Um valor gravado fora das opções aparece marcado como fora da lista e é preservado. Na lista, os valores já gravados mantêm a ordem gravada e os novos seguem a ordem das opções: enviar o formulário sem mudança devolve a mesma regra e é recusado como edição sem mudança.

### Filas, equipes e analistas

Gravados só por `Admin::QueueEditor`, `Admin::TeamEditor` e `Admin::AttendantEditor` (base `Admin::Editor`, `core/app/modules/admin/`), cada edição em um `Tenancy.with_brand`, pelo `Audit::Command`:

| Editor | Atributos | Eventos |
| - | - | - |
| `Admin::QueueEditor` | `name`, `team_id`, `sla_minutes`, `capacity`, `first_attendant`, `overflow_queue_id`, `escalation_queue_id` | `queue.created`, `queue.updated` |
| `Admin::TeamEditor` | `name`, `skills`, `business_hours` | `team.created`, `team.updated` |
| `Admin::AttendantEditor` | `name`, `team_id`, `capacity`, `skills` | `attendant.created`, `attendant.updated` |

Cada evento leva `before` (nulo na criação), `after` e payload com `operation`, `diff` (antes e depois de cada atributo que muda) e `operator_name`, sem webhook e sem atualização do painel. Na edição, o registro é lido com `FOR UPDATE`; o formulário leva o `updated_at` lido (ISO 8601 com microssegundos), e se ele mudou a edição é recusada. As recusas:

| Recusa | Exceção |
| - | - |
| O registro mudou depois de lido | `Admin::Stale` |
| A edição não muda nenhum atributo | `Admin::Unchanged` |
| Validação do model ou do editor, com uma mensagem por problema | `Admin::Invalid` |
| Edição do atendente IA | `Admin::NotAllowed` |
| Atributo fora da lista do editor | `ArgumentError` |

Validações próprias de cada editor:

- **fila:** nome repetido na marca; equipe, fila de transbordo ou fila de escalação que não existe na marca; renomear a fila quando a maior versão de alguma regra, ativa ou não, cita o nome atual em `then.queue` (a mensagem lista as regras; versões anteriores não contam); `first_attendant` `ai` na fila que é fila de escalação de outra; trocar a equipe quando uma regra vigente com `when.hours` tem a fila como destino e a equipe nova não tem horário comercial válido. O transbordo pode formar ciclo; o `Routing::Route` para ao revisitar uma fila;
- **equipe:** nome repetido na marca; horário comercial preenchido e inválido; horário vazio ou inválido quando uma regra vigente com `when.hours` tem como destino uma fila da equipe. As habilidades são limpas de espaços, vazios e repetições;
- **analista:** é sempre `human` (o `kind` nos atributos é recusado); equipe que não existe na marca.

Os editores de fila e de equipe rodam sob a mesma `Routing::RoutingLock` das regras: a conferência contra as regras e a gravação acontecem sem outra gravação de regra, fila ou equipe da marca no meio.

### Histórico

`Admin::History` lê `audit_events` na marca: `for_record` devolve os eventos cujo alvo é a fila, a equipe ou o analista; `for_rule` devolve os `routing_rule.published` de todas as versões de uma regra, pelo `rule_id` do payload. As telas mostram o operador, o horário e o diff de cada evento.

## O que o sistema garante

- Uma regra editada vale para a próxima conversa, sem deploy, e a edição aparece na auditoria e na tela da regra.
- Uma capacidade reduzida no admin vale no próximo roteamento: a fila cheia transborda.
- Toda versão de regra é uma linha imutável; a anterior continua gravada.
- Toda marca mantém uma regra genérica ativa.
- Nenhuma regra fica apontando para uma fila renomeada, e nenhuma regra de horário fica sem horário comercial no destino.
- Duas edições simultâneas do mesmo registro não se sobrescrevem: a segunda é recusada pela versão lida.
- Toda edição grava um `audit_event` com o operador, o diff e o horário; nenhuma recusa deixa gravação.
- O admin não apaga registros e não edita o atendente IA.
- Toda leitura e escrita respeita a marca da sessão.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega | O que fica com outras partes |
| - | - | - |
| Múltiplas filas configuráveis e editáveis pela operação | Telas de filas, equipes, analistas e regras, com versões e efeito imediato | Classificação, roteamento e distribuição (F6) |
| Triagem, priorização e distribuição | Prioridade, SLA, atendente inicial, capacidade e transbordo editáveis | Avaliação das regras e distribuição por capacidade (F6) |
| Rastreabilidade e auditoria | `routing_rule.published` e eventos de edição com operador e diff; histórico nas telas | `Audit::Command` e `audit_events` (F2), "Por que caiu aqui?" (F11) |
| Multi-marca | Marca na sessão, `Tenancy.with_brand` em toda leitura e escrita | RLS (F1) |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 a H4 | A capacidade das filas e as regras que valem durante a carga são dados editáveis no admin, sem deploy, e cada ajuste fica registrado na auditoria |

## Diferenciais

| Diferencial | Contribuição desta parte |
| - | - |
| 3 · "Por que caiu aqui?" | A regra e a versão mostradas na conversa são as gravadas pelo `Routing::RulePublisher`; a tela da regra no admin mostra o diff de cada versão |

## Limitações

- **Login simulado.** O operador é o usuário do basic auth; não há contas nem papéis por operador.
- **Sem exclusão.** Filas, equipes e analistas sem uso continuam na lista; regras são só desativadas.
- **Sem simulação da regra.** A edição não mostra antes quais conversas mudariam de fila.
- **Renomear fila em dois passos.** Com regras citando a fila, o operador muda as regras antes de renomear.
- **Horários em UTC.** As telas do admin mostram os horários em UTC, sem o fuso da equipe.

## Operação

### Acesso

`http://localhost:3000/admin`, com `ADMIN_USER` e `ADMIN_PASSWORD` do `.env`. A primeira tela escolhe a marca.

### Configuração

| Variável ou arquivo | Uso |
| - | - |
| `ADMIN_USER`, `ADMIN_PASSWORD` | Basic auth do admin; o usuário é o `operator_name` dos eventos |
| `core/config/routing/dimensions.yml` | Segmentos e idiomas por marca: opções do formulário de regra e valores das seeds |
| `core/config/routing/classifier.yml` | Categorias da marca: opções de `when.category` |

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/requests/admin/rule_takes_effect_spec.rb` | A regra editada no admin vale na próxima mensagem, com a versão 2 no `conversation.routed` e o diff e o operador no `routing_rule.published`; a capacidade reduzida faz a fila cheia transbordar no próximo roteamento |
| `core/spec/requests/admin/rules_spec.rb` | Lista em ordem de avaliação; criação e edição pelo formulário; versões e diff; definição inválida e versão antiga com `422`; valor fora da lista preservado; ativar e desativar; recusa de desativar a regra genérica; regra de outra marca |
| `core/spec/requests/admin/queues_spec.rb`, `teams_spec.rb`, `attendants_spec.rb` | Lista, criação, edição e histórico; recusas com `422`; `updated_at` antigo; `operator_name` do basic auth com `actor_id` nulo; atendente IA só para leitura; registro de outra marca |
| `core/spec/requests/admin/sessions_spec.rb` | `401` sem credencial, com senha errada e com as variáveis vazias; escolha e troca da marca; páginas internas sem marca voltam à escolha; nenhuma rota de exclusão |
| `core/spec/modules/admin/queue_editor_spec.rb`, `team_editor_spec.rb`, `attendant_editor_spec.rb` | Eventos com `before`, `after` e diff; `Stale`, `Unchanged`, `Invalid` e `NotAllowed`; nome repetido por marca; fila renomeada com regra (ativa ou inativa); fila de escalação humana; horário comercial exigido por regra `hours`; transbordo em ciclo; rollback sem evento |
| `core/spec/modules/admin/rule_form_spec.rb` | Conversão do formulário; opções de `Routing::Dimensions`; valor fora da lista preservado; ordem dos valores; cada regra das seeds enviada sem mudança é recusada como `Unchanged` |
| `core/spec/modules/admin/history_spec.rb` | Eventos do registro em ordem, versões de uma regra pelo `rule_id`, isolamento por marca |
| `core/spec/modules/routing/rule_publisher_spec.rb` | Versões, `routing_rule.published` com autor e diff, recusas, regra genérica por marca, `operator_name`, `expected_version` e a `Routing::RoutingLock` |
| `core/spec/modules/routing/dimensions_spec.rb`, `compiled_rules_spec.rb` | Opções por marca e regras compiladas no cache |

No Compose, `/admin` responde `401` sem credencial; com o basic auth, a escolha da marca redireciona às regras, e as telas de regras, filas, equipes, atendentes e nova regra respondem `200`.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco e entidades (F1) | `routing_rules`, `queues`, `teams` e `attendants`, com RLS e `brand_id` |
| Núcleo transacional e auditoria (F2) | Toda gravação pelo `Audit::Command`, com o envelope em `audit_events` |
| Triagem, roteamento e distribuição (F6) | `Routing::RulePublisher`, `Routing::RuleDefinition`, `Routing::CompiledRules` e `Routing::Route`, que lê as regras e as filas editadas |
| Handoff, painel e timeout (F11) | "Por que caiu aqui?" com a regra e a versão; fila de escalação editada no admin; `panel:demo_sla` publica pelo mesmo `Routing::RulePublisher` |
| Observabilidade (F14) | Profundidade e risco de SLA por nome de fila no cockpit |

## Fontes

- `documents/arquitetura.md`, seção "Filas configuráveis pela operação"
- `documents/fases/07-triagem-roteamento-e-distribuicao.md`
- `documents/fases/02-banco-multi-marca-e-entidades.md`
- Código e testes de `core/app/controllers/admin/`, `core/app/modules/admin/` e `core/app/modules/routing/`

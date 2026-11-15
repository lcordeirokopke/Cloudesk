# Cloudesk · F0 · Repositório e infraestrutura local

## Objetivo

A F0 entrega o ambiente que todas as outras fases usam: estrutura do repositório, app Rails com os módulos vazios, Solid Queue, Solid Cable e Solid Cache no mesmo banco do app, papéis de banco, Docker Compose com a infraestrutura e os frameworks de teste.

Este documento detalha cada definição e a fonte que a sustenta. As entregas e o critério de pronto da fase estão em `contexto/ordem-de-implementacao.md`; a arquitetura que prevalece está em `documents/arquitetura.md`.

## Resumo das definições

| Tema | Definição |
| - | - |
| Repositório | Uma pasta por componente: `core/`, `agent_mock/`, `channel_simulator/`, `experiment/`, `infra/` |
| Módulos do Core | Namespaces em `core/app/modules/` |
| Rails | 8.1, app completo com Hotwire, banco PostgreSQL, Active Storage ligado |
| Ambiente de desenvolvimento | Tudo em contêiner; a máquina precisa só de Docker |
| Solid Queue, Cable e Cache | No banco principal, conforme os passos de banco único de cada README |
| Papéis de banco | Papel dono e papel da aplicação criados pelo script de inicialização do Postgres |
| Compose | `postgres`, `redpanda`, `redpanda-init`, `mailpit` e `web` |
| Tópicos | `agent.inbound` e `agent.outbound` com 6 partições, e `agent.dlq`, criados por `rpk` |
| Python | `pyproject.toml` com `pip` |
| Testes | RSpec em `core/`; pytest em `agent_mock/` e `channel_simulator/` |

## Estrutura de diretórios

```text
Cloudwalk/
├── core/                 app Rails 8 (Core + código do Broker), com Dockerfile próprio
│   ├── app/
│   │   ├── models/           entidades (F1)
│   │   ├── modules/          channels/ conversations/ routing/ agents/ audit/ admin/
│   │   └── controllers/ jobs/ views/ ...
│   ├── config/           database.yml, queue.yml, cable.yml, cache.yml
│   ├── db/               migrate/, structure.sql
│   └── spec/             RSpec
├── agent_mock/           Python: pyproject.toml, src/, tests/
├── channel_simulator/    Python: pyproject.toml, src/, tests/
├── experiment/           k6 e análise (F17)
├── infra/
│   ├── postgres/init/    script de criação dos papéis e dos bancos
│   └── redpanda/         script de criação dos tópicos
├── documents/
├── contexto/
├── compose.yaml
└── README.md
```

**Embasamento.**

- **Uma pasta por componente.** A F0 lista cinco componentes: Core Rails (que contém o código do Broker), agente mock, simulador de canais, experimento e infraestrutura.
- **Módulos como namespaces.** O guia de autoloading do Rails afirma: "Rails adds custom directories under app to the autoload paths automatically" e "In a Rails application file names have to match the constants they define, with directories acting as namespaces". Com isso, `core/app/modules/routing/` define constantes em `Routing`, sem configuração adicional. A F0 cria os seis módulos vazios: `Channels`, `Conversations`, `Routing`, `Agents`, `Audit` e `Admin`.
- **Sem engines e sem Packwerk.** Nenhum requisito do enunciado depende deles, e a arquitetura adota infraestrutura proporcional ao problema.
- **Arquivos do Broker.** `karafka.rb`, os consumers e o endpoint Rack nascem na F9. A F0 não os cria.

## App Rails

| Item | Definição | Embasamento |
| - | - | - |
| Versão | Rails 8.1 (8.1.4.1 é a estável em novembro de 2026) | rubyonrails.org e RubyGems; exige Ruby >= 3.2. O Karafka exige "Rails 7.2 or newer" |
| Tipo de app | Completo, não somente API | A arquitetura pede API + Hotwire: chat, painel e admin são telas |
| Banco | PostgreSQL, escolhido na opção de banco do `rails new` | Guia de linha de comando do Rails: o padrão do `rails new` é SQLite |
| Active Storage | Ligado | O guia do Action Mailbox informa que o `InboundEmail` guarda o e-mail original via Active Storage, e que pular o Active Storage também pula o Action Mailbox. A F4 depende dele |
| Kamal | Fora do app | O deploy com Kamal está na seção "Evolução" da arquitetura |
| Framework de teste padrão | Fora do app | Os testes do Core são RSpec |
| Dockerfile | O gerado pelo Rails | As notas do Rails 8.0 informam que o Dockerfile gerado inclui o proxy Thruster à frente do Puma |

Os nomes exatos das opções de "pular" do `rails new` são confirmados na ajuda do próprio comando no momento da geração; o guia remete a ela para a lista completa.

**Ambiente de desenvolvimento.** O app é gerado e executado em contêiner. A máquina de desenvolvimento precisa só de Docker e Docker Compose.

## Papéis e bancos

O script em `infra/postgres/init/` roda na primeira inicialização do contêiner do Postgres e cria:

- o **papel dono**, sem superusuário e sem `BYPASSRLS`;
- o **papel da aplicação**, sem superusuário e sem `BYPASSRLS`;
- os bancos de desenvolvimento e de teste, com o papel dono como dono.

Uso dos papéis na F0:

- as migrações rodam com o papel dono;
- o `web` e os testes conectam com o papel da aplicação;
- a migração que cria as tabelas do Solid Queue, Solid Cable e Solid Cache concede ao papel da aplicação `SELECT`, `INSERT`, `UPDATE` e `DELETE` nessas tabelas e o uso das sequences delas.

As permissões nas tabelas de domínio e o RLS são entregas da F1 (`documents/f1-banco-multi-marca-e-entidades.md`).

**Embasamento.**

- **Superusuário da imagem.** O README da imagem oficial informa que `POSTGRES_USER` "will create the specified user with superuser power". Ele serve só para rodar o script de inicialização.
- **Momento da criação.** Os arquivos em `/docker-entrypoint-initdb.d` "are only run if you start the container with a data directory that is empty". Por isso os papéis nascem junto com o banco, na F0.
- **Papéis sem privilégio.** A documentação do PostgreSQL afirma que superusuários e papéis com `BYPASSRLS` ignoram o RLS; os dois papéis nascem sem esses atributos.

## Solid Queue, Solid Cable e Solid Cache no banco principal

| Peça | Passos | Fonte |
| - | - | - |
| Solid Queue | Copiar o conteúdo de `db/queue_schema.rb` para uma migração normal, apagar o arquivo e remover `config.solid_queue.connects_to` | README, seção "Single database configuration" |
| Solid Cable | Copiar o conteúdo de `db/cable_schema.rb` para uma migração normal, apagar o arquivo e remover `connects_to` de `config/cable.yml` | README do Solid Cable |
| Solid Cache | Deixar `config/cache.yml` sem `database`, `databases` e `connects_to` | README: "If none of these are set, Solid Cache will use the ActiveRecord::Base connection pool" |

Com banco único, o `database.yml` tem uma só entrada por ambiente.

**Pontos de atenção.**

- **Solid Queue.** O README afirma: "Running Solid Queue in a separate database is recommended, but it's also possible to use one single database for both the app and the queue". O Cloudesk usa o banco único de propósito: é o que torna atômica a gravação da mensagem junto com o job de webhook (outbox implícito).
- **Solid Cache.** No pool principal, "cache reads and writes will be part of any wrapping database transaction". Uma escrita de cache feita dentro de uma transação desfeita some com ela.
- **Schema do Solid Cache.** O README não traz os passos para levar o schema do cache ao banco principal. A F0 aplica o mesmo procedimento do Solid Queue e do Solid Cable: copiar o schema para uma migração normal. Esse passo é verificado na implementação.
- **Solid Cable.** O padrão é consultar o banco a cada 0,1 s e reter as mensagens por 1 dia; o README indica que poucos minutos de retenção bastam para a maioria dos apps. O ajuste fica para a F15.
- **Adaptador em todos os ambientes.** O Solid Queue é o adaptador de jobs em desenvolvimento, teste e produção. O critério de pronto da F0 exige um job gravado na base do app e executado.

## Docker Compose

| Serviço | Imagem | Configuração |
| - | - | - |
| `postgres` | `postgres:18` | Volume montado em `/var/lib/postgresql`; scripts de inicialização em `infra/postgres/init/` |
| `redpanda` | `docker.redpanda.com/redpandadata/redpanda:v26.2.7` | Um nó, modo `dev-container`, 1 núcleo, listener interno na 9092 e externo na 19092 |
| `redpanda-init` | Mesma imagem do `redpanda` | Roda o script de `infra/redpanda/` e termina |
| `mailpit` | `axllent/mailpit` | SMTP na 1025, interface web e API na 8025 |
| `web` | Imagem do Core | Puma |

Os demais serviços da aplicação (`jobs-webhooks`, `jobs-default`, `broker-web`, `broker-consumer`, `agent-mock`) entram no Compose na fase que cria cada um.

**Embasamento.**

- **Volume do PostgreSQL 18.** O README da imagem oficial informa que o `PGDATA` "was changed to be version specific in PostgreSQL 18 and above" e que "The defined VOLUME was changed in 18 and above to /var/lib/postgresql".
- **Redpanda de um nó.** A configuração segue o exemplo oficial de broker único, que usa o modo `dev-container` e 1 núcleo.
- **Uma imagem, vários papéis.** Os serviços Rails compartilham um bloco comum por âncora YAML e mudam o `command`. A documentação do Compose afirma: "Anchors and aliases let you create reusable blocks". O Chatwoot usa o mesmo desenho em produção: `rails` e `sidekiq` herdam a imagem de um bloco `base` e diferem no comando.
- **Redpanda Console.** Fica fora: não está na lista de contêineres da arquitetura.

## Tópicos

| Tópico | Partições | Uso |
| - | - | - |
| `agent.inbound` | 6 | Eventos do Core para o agente |
| `agent.outbound` | 6 | Ações do agente para o Core |
| `agent.dlq` | Padrão do cluster | Mensagens que o `broker-consumer` não consegue processar |

- O script de `infra/redpanda/` cria os três tópicos com `rpk topic create`, com a opção de não falhar quando o tópico já existe. O fator de replicação é 1, pois o ambiente tem um único nó.
- O número de partições limita quantas instâncias de `broker-consumer` e de `agent-mock` consomem em paralelo: até 6 por grupo consumidor.
- O tópico `agent.dlq` é criado pelo script porque o Karafka não o cria.

**Embasamento.**

- O quickstart da Redpanda usa um serviço do Compose que cria o tópico com a opção de não falhar se ele já existe. O `rpk topic create` define partições com `-p` e réplicas com `-r`.
- O agente mock, em Python, também depende dos tópicos; por isso a criação não fica no Karafka.
- A documentação do Karafka afirma que a opção `topic:` de `dead_letter_queue` "only tells Karafka where to dispatch failed messages".

## Python

- `agent_mock/` e `channel_simulator/` são projetos independentes, cada um com `pyproject.toml`, código em `src/` e testes em `tests/`.
- As dependências são instaladas com `pip`.
- A F0 entrega os dois projetos com o pytest rodando; o código do agente nasce na F10 e o do simulador na F5.

## Testes

- **Core e Broker:** RSpec, em `core/spec/`.
- **Agente mock e simulador de canais:** pytest, em `tests/` de cada projeto.

## Pronto quando

O critério é o de `contexto/ordem-de-implementacao.md`:

- o Compose sobe todos os serviços de infraestrutura;
- o Rails conecta diretamente ao Postgres, com o papel da aplicação;
- um job de teste é gravado na mesma base do app e executado;
- os tópicos existem no Redpanda.

## Reflexos em outras fases

| Fase | Fato | Tratamento |
| - | - | - |
| F1 | `Queue` é uma classe do Ruby (`Thread::Queue`, disponível no nível raiz). Um model `Queue < ApplicationRecord` no nível raiz entra em conflito com ela | O model da entidade é `Routing::Queue`, em `core/app/models/routing/queue.rb`, com a tabela `queues` |
| F9 | Na versão open source do Karafka, a mensagem enviada à DLQ pelo recurso `dead_letter_queue` preserva só o payload: "headers are not included", e a chave não é definida | O `broker-consumer` publica em `agent.dlq` com o próprio produtor, preservando chave, headers e payload |
| F4 | O Mailpit oferece webhook para mensagem recebida, encaminhamento por SMTP e relay por SMTP. O Action Mailbox oferece o ingress `relay`, que recebe o e-mail por HTTP com senha | A ligação entre os dois é ponto em aberto, decidido antes da F4 |

## Fontes

- [Rails 8.0 Release Notes](https://guides.rubyonrails.org/8_0_release_notes.html)
- [Rails no RubyGems](https://rubygems.org/gems/rails)
- [Rails Guides - Command Line](https://guides.rubyonrails.org/command_line.html)
- [Rails Guides - Autoloading](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [Rails Guides - Action Mailbox](https://guides.rubyonrails.org/action_mailbox_basics.html)
- [Solid Queue README](https://github.com/rails/solid_queue)
- [Solid Cable README](https://github.com/rails/solid_cable)
- [Solid Cache README](https://github.com/rails/solid_cache)
- [Karafka - Getting Started](https://karafka.io/docs/Basics-Getting-Started.md)
- [Karafka - Rails integration](https://karafka.io/docs/Infrastructure-Integrating-with-Ruby-on-Rails-and-other-frameworks.md)
- [Karafka - Dead Letter Queue](https://karafka.io/docs/Consumer-Groups-Dead-Letter-Queue.md)
- [Redpanda - Single broker Docker Compose](https://docs.redpanda.com/redpanda-labs/docker-compose/single-broker/)
- [Redpanda - Quickstart](https://docs.redpanda.com/current/get-started/quick-start/)
- [Redpanda - rpk topic create](https://docs.redpanda.com/current/reference/rpk/rpk-topic/rpk-topic-create/)
- [Mailpit - Docker](https://mailpit.axllent.org/docs/install/docker/)
- [Mailpit - SMTP forward](https://mailpit.axllent.org/docs/configuration/smtp-forward/)
- [PostgreSQL Docker image README](https://github.com/docker-library/docs/blob/master/postgres/README.md)
- [PostgreSQL 18 - Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- [Chatwoot - docker-compose.production.yaml](https://raw.githubusercontent.com/chatwoot/chatwoot/develop/docker-compose.production.yaml)
- [Docker Compose - Fragments](https://docs.docker.com/reference/compose-file/fragments/)

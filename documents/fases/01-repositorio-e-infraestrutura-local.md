# Cloudesk · F0 · Repositório e infraestrutura local

## Objetivo

A F0 entrega o ambiente que todas as outras fases usam: estrutura do repositório, app Rails com os módulos vazios, Solid Queue, Solid Cable e Solid Cache no mesmo banco do app, papéis de banco, Docker Compose com a infraestrutura e os frameworks de teste.

Este documento detalha cada definição e a fonte que a sustenta. As entregas e o critério de pronto da fase estão em `contexto/ordem-de-implementacao.md`; a arquitetura que prevalece está em `documents/arquitetura.md`.

## Resumo das definições

| Tema | Definição |
| - | - |
| Repositório | Uma pasta por componente: `core/`, `agent_mock/`, `channel_simulator/`, `experiment/`, `infra/` |
| Módulos do Core | Namespaces em `core/app/modules/` |
| Rails | 8.1, app completo com Hotwire, banco PostgreSQL, Active Storage ligado; Ruby 3.4 |
| Ambiente de desenvolvimento | Tudo em contêiner; a máquina precisa só de Docker. Imagem de desenvolvimento e teste em `core/Dockerfile.dev` |
| Solid Queue, Cable e Cache | No banco principal, conforme os passos de banco único de cada README |
| Papéis de banco | `cloudesk_owner` (dono) e `cloudesk_app` (aplicação), criados pelo script de inicialização do Postgres |
| Credenciais | `.env` na raiz, criado a partir do `.env.example`; o `.env` não é versionado |
| Schema | `db/structure.sql`, com os `GRANT` e `REVOKE` do banco |
| Compose | `postgres`, `redpanda`, `redpanda-init`, `mailpit` e `web` |
| Tópicos | `agent.inbound` e `agent.outbound` com 6 partições, e `agent.dlq`, criados por `rpk` |
| Python | `pyproject.toml` com `pip` |
| Testes | RSpec em `core/`; pytest em `agent_mock/` e `channel_simulator/` |

## Estrutura de diretórios

```text
Cloudwalk/
├── core/                 app Rails 8 (Core + código do Broker)
│   ├── Dockerfile        imagem de produção, gerada pelo Rails
│   ├── Dockerfile.dev    imagem de desenvolvimento e teste, usada pelo Compose
│   ├── app/
│   │   ├── models/           entidades (F1)
│   │   ├── modules/          channels/ conversations/ routing/ agents/ audit/ admin/
│   │   └── controllers/ jobs/ views/ ...
│   ├── config/           database.yml, queue.yml, cable.yml, cache.yml
│   ├── db/               migrate/, structure.sql
│   ├── lib/tasks/        structure_privileges.rake
│   └── spec/             RSpec
├── contracts/            contrato entre Core, Broker e agente (F3)
├── agent_mock/           Python: pyproject.toml, src/, tests/
├── channel_simulator/    Python: pyproject.toml, src/, tests/
├── experiment/           k6 e análise (F17)
├── infra/
│   ├── postgres/init/    script de criação dos papéis e dos bancos
│   └── redpanda/         script de criação dos tópicos
├── documents/
├── contexto/
├── .env.example          nomes dos papéis e dos bancos; senhas preenchidas no .env
├── .gitattributes        final de linha LF nos scripts e Dockerfiles
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
| Ruby | 3.4 (imagem `ruby:3.4`; `.ruby-version` com 3.4.12) | O Rails 8.1.4.1 instala e roda nessa versão |
| Nome do app | `Cloudesk`, na pasta `core/` | Gerado com a opção de nome do `rails new` |
| Tipo de app | Completo, não somente API | A arquitetura pede API + Hotwire: chat, painel e admin são telas |
| Banco | PostgreSQL, escolhido na opção de banco do `rails new` | Guia de linha de comando do Rails: o padrão do `rails new` é SQLite |
| Active Storage | Ligado | O guia do Action Mailbox informa que o `InboundEmail` guarda o e-mail original via Active Storage, e que pular o Active Storage também pula o Action Mailbox. A F4 depende dele |
| Kamal | Fora do app | O deploy com Kamal está na seção "Evolução" da arquitetura |
| Framework de teste padrão | Fora do app | Os testes do Core são RSpec (`rspec-rails` 8.1.0) |
| CI do GitHub, devcontainer, RuboCop, Brakeman e bundler-audit | Fora do app | Nenhum requisito do enunciado depende deles |
| Dockerfile | O gerado pelo Rails, para produção | As notas do Rails 8.0 informam que o Dockerfile gerado inclui o proxy Thruster à frente do Puma |
| Dockerfile.dev | Imagem de desenvolvimento e teste | O Dockerfile gerado define `RAILS_ENV=production` e exclui as gems de desenvolvimento e teste; o RSpec e o modo de desenvolvimento precisam delas |

Os nomes exatos das opções de "pular" do `rails new` são confirmados na ajuda do próprio comando no momento da geração; o guia remete a ela para a lista completa.

**Ambiente de desenvolvimento.** O app é gerado e executado em contêiner. A máquina de desenvolvimento precisa só de Docker e Docker Compose.

**Imagem do Core.** O `core/Dockerfile.dev` parte de `ruby:3.4-slim`, instala o `postgresql-client-18` do repositório oficial PGDG e as gems do `Gemfile.lock`. O Compose monta `core/` como volume, de modo que alterações no código valem sem reconstruir a imagem. O `pg_dump` precisa ser da mesma versão do servidor para gerar o `db/structure.sql`; o cliente do Debian da imagem base é de versão anterior.

**Active Storage.** O Active Storage fica ligado no app, e as tabelas dele nascem na F4, junto com o Action Mailbox.

## Papéis e bancos

O script em `infra/postgres/init/` roda na primeira inicialização do contêiner do Postgres e cria:

- o **papel dono** `cloudesk_owner`, sem superusuário, sem `BYPASSRLS` e sem `CREATEDB`;
- o **papel da aplicação** `cloudesk_app`, sem superusuário, sem `BYPASSRLS` e sem `CREATEDB`;
- os bancos `cloudesk_development` e `cloudesk_test`, com o papel dono como dono.

Os nomes e as senhas chegam por variável de ambiente, a partir do `.env`. O `database.yml` lê `DB_USERNAME` e `DB_PASSWORD`; o Compose entrega ao `web` as credenciais do papel da aplicação, e os comandos de migração recebem as do papel dono.

Uso dos papéis na F0:

- as migrações rodam com o papel dono;
- o `web` e os testes conectam com o papel da aplicação;
- a migração que cria as tabelas do Solid Queue, Solid Cable e Solid Cache concede ao papel da aplicação `SELECT`, `INSERT`, `UPDATE` e `DELETE` nessas tabelas, o uso das sequences delas e só `SELECT` em `schema_migrations` e `ar_internal_metadata`. Em development, o Rails confere migrações pendentes a cada requisição lendo essas duas tabelas com o papel da aplicação.

As permissões nas tabelas de domínio e o RLS são entregas da F1 (`documents/fases/02-banco-multi-marca-e-entidades.md`).

### Schema com permissões

- O Rails gera o `db/structure.sql` com `pg_dump` sem privilégios, e em banco vazio o `db:migrate` carrega esse arquivo em vez de rodar as migrações. Sem os `GRANT`, um banco novo deixaria o papel da aplicação sem acesso.
- A task `core/lib/tasks/structure_privileges.rake` estende o `db:schema:dump` e acrescenta ao arquivo as linhas `GRANT` e `REVOKE` do banco. Um banco carregado do schema fica com as mesmas permissões do banco migrado.
- Os nomes dos papéis ficam gravados no arquivo e por isso são fixos.
- O banco de teste é montado com `RAILS_ENV=test bin/rails db:migrate` e o papel dono. Em banco vazio, esse comando carrega o `structure.sql` com as permissões; o RSpec não usa `maintain_test_schema!`, pois o papel da aplicação não cria tabelas. O `db:test:prepare` fica fora: ele apaga e recria o banco, o que exigiria `CREATEDB`.

**Embasamento.** No código do ActiveRecord 8.1.4.1, `PostgreSQLDatabaseTasks#structure_dump` chama o `pg_dump` com as opções de só schema, sem privilégios e sem dono; `DatabaseTasks#initialize_database` carrega o schema quando o banco não tem `schema_migrations`; e `purge`, usado pelo `db:test:prepare`, faz `drop` e `create`.

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
- **Schema do Solid Cache.** O README não traz os passos para levar o schema do cache ao banco principal. A F0 aplica o mesmo procedimento do Solid Queue e do Solid Cable: copiar o schema para uma migração normal. As três peças ficam em uma única migração, `db/migrate/20261115120000_create_solid_tables.rb`, e os arquivos `db/*_schema.rb` são apagados.
- **Solid Cable.** O padrão é consultar o banco a cada 0,1 s e reter as mensagens por 1 dia; o README indica que poucos minutos de retenção bastam para a maioria dos apps. O ajuste fica para a F15.
- **Adaptador em todos os ambientes.** O Solid Queue é o adaptador de jobs em desenvolvimento, teste e produção, definido em `config/application.rb`. O critério de pronto da F0 exige um job gravado na base do app e executado.
- **Solid Cable e Solid Cache por ambiente.** Os dois rodam no banco do app em desenvolvimento e produção. Em teste, o Action Cable usa o adaptador `test` e o cache usa `null_store`.

## Docker Compose

| Serviço | Imagem | Configuração |
| - | - | - |
| `postgres` | `postgres:18` | Volume montado em `/var/lib/postgresql`; scripts de inicialização em `infra/postgres/init/` |
| `redpanda` | `docker.redpanda.com/redpandadata/redpanda:v26.2.7` | Um nó, modo `dev-container`, 1 núcleo, listener interno na 9092 e externo na 19092 |
| `redpanda-init` | Mesma imagem do `redpanda` | Roda o script de `infra/redpanda/` e termina |
| `mailpit` | `axllent/mailpit` | SMTP na 1025, interface web e API na 8025 |
| `web` | Imagem do Core (`cloudesk-core:dev`, de `core/Dockerfile.dev`) | Puma na 3000, em `RAILS_ENV=development`, com o papel da aplicação |

Portas publicadas no host: 3000 (`web`), 1025 e 8025 (`mailpit`) e 19092 (`redpanda`). O Postgres não fica exposto no host.

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
- O script define `message.timestamp.type=LogAppendTime` em `agent.inbound`: o timestamp do registro é o horário de gravação no Kafka, usado pelo contrato da F3 (`documents/fases/04-contrato-de-integracao.md`).

**Embasamento.**

- O quickstart da Redpanda usa um serviço do Compose que cria o tópico com a opção de não falhar se ele já existe. O `rpk topic create` define partições com `-p` e réplicas com `-r`.
- O agente mock, em Python, também depende dos tópicos; por isso a criação não fica no Karafka.
- A documentação do Karafka afirma que a opção `topic:` de `dead_letter_queue` "only tells Karafka where to dispatch failed messages".

## Python

- `agent_mock/` e `channel_simulator/` são projetos independentes, cada um com `pyproject.toml`, código em `src/` e testes em `tests/`.
- As dependências são instaladas com `pip`.
- Os dois projetos exigem Python 3.13 ou superior; o pytest é o extra `test` do `pyproject.toml`.
- A F0 entrega os dois projetos com o pytest rodando, cada um com um teste de fumaça que importa o pacote de `src/`. Sem nenhum teste, o pytest termina com código 5. O código do agente nasce na F10 e o do simulador na F5.

## Testes

- **Core e Broker:** RSpec, em `core/spec/`. O `SmokeJob` (`core/app/jobs/smoke_job.rb`) e o `spec/jobs/smoke_job_spec.rb` provam o critério de pronto do job: o adaptador é o Solid Queue, ele usa a mesma conexão do app, e o job é gravado em `solid_queue_jobs` e executado pelo caminho do worker (`ReadyExecution.claim` e `ClaimedExecution#perform`).
- **Agente mock e simulador de canais:** pytest, em `tests/` de cada projeto.

## Final de linha

O `.gitattributes` da raiz força LF nos `.sh`, nos Dockerfiles e em `core/bin/*`. Com `core.autocrlf=true` no Windows, um script com CRLF falha dentro do contêiner.

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
| F1 | O `db/structure.sql` recebe os `GRANT` e `REVOKE` do banco pela task `structure_privileges.rake` | As permissões das migrações da F1 entram no arquivo sem passo adicional; os nomes dos papéis são fixos |
| F4 | O Active Storage está ligado; as tabelas dele e a do Action Mailbox não têm `brand_id` | As tabelas são criadas na F4, sem RLS e com a chave primária `bigint` das gems; o papel da aplicação tem `SELECT`, `INSERT`, `UPDATE` e `DELETE` (`documents/fases/05-canais-de-entrada-e-identidade.md`) |
| F4 | O Mailpit oferece webhook para mensagem recebida, encaminhamento por SMTP e relay por SMTP. O Action Mailbox oferece o ingress `relay`, que recebe o e-mail por HTTP com senha | A F4 usa o webhook do Mailpit e um job recorrente que busca os e-mails sem tag; o ingress `relay` não é usado (`documents/fases/05-canais-de-entrada-e-identidade.md`) |

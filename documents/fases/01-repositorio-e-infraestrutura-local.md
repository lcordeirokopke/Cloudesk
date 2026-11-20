# Cloudesk · Repositório e infraestrutura local

## O que é

O repositório e a infraestrutura local são a base sobre a qual todo o Cloudesk roda. Esta parte define:

- **a organização do repositório**, com uma pasta por componente;
- **o app Rails** do Core, com os módulos de domínio como namespaces;
- **o ambiente em contêiner**: o Docker Compose sobe o PostgreSQL, o Redpanda, o Mailpit e todos os processos da aplicação, e a máquina de desenvolvimento precisa só de Docker;
- **o PostgreSQL como único sistema de estado**, com Solid Queue, Solid Cable e Solid Cache no mesmo banco do app;
- **os papéis de banco**, criados na inicialização do Postgres;
- **os tópicos Kafka**, criados por script;
- **os frameworks de teste**: RSpec no Ruby e pytest no Python.

## Onde fica no fluxo

```text
docker compose up
  ├─ postgres ── infra/postgres/init: papéis cloudesk_owner e cloudesk_app, bancos de dev e teste
  ├─ redpanda ── redpanda-init: agent.inbound, agent.outbound (6 partições) e agent.dlq
  ├─ mailpit ─── SMTP 1025, API e interface 8025
  ├─ web, jobs-default, jobs-webhooks ─┐
  ├─ broker-web, broker-consumer ──────┴─ mesma imagem cloudesk-core:dev, comandos diferentes
  ├─ channel-simulator
  └─ agent-mock
```

## Por que existe e que valor gera

**Um comando sobe o sistema inteiro.** O Compose sobe toda a infraestrutura e todos os processos, sem nada instalado na máquina além do Docker. Quem avalia o projeto roda o mesmo ambiente de quem o desenvolveu, e o experimento roda sobre esse mesmo ambiente.

**Um único sistema de estado.** Jobs, tempo real e cache ficam no PostgreSQL do app. A gravação da mensagem e do job de webhook cabe na mesma transação (outbox implícito), e não existe Redis nem dual-write para manter em sincronia.

**Escala por papel, com uma imagem só.** `web`, `jobs-default`, `jobs-webhooks`, `broker-web` e `broker-consumer` usam a mesma imagem e o mesmo código, com comandos diferentes. Cada papel escala pelo número de réplicas, conforme a própria carga, e a falha de um não derruba os outros.

**Infraestrutura proporcional ao problema.** Cada componente existe porque um requisito ou uma hipótese do experimento depende dele: PostgreSQL para estado e filas, Redpanda para o broker, Mailpit para o canal de e-mail. Engines, Packwerk, Kamal e ferramentas de CI ficam fora.

**Segurança desde a primeira linha.** Os papéis de banco nascem sem superusuário, sem `BYPASSRLS` e sem `CREATEDB`, e a aplicação conecta com um papel que não é dono das tabelas. O isolamento por marca construído em cima disso não depende de o código acertar o papel.

## Como funciona

### Repositório

```text
Cloudwalk/
├── core/                 app Rails (Core e código do Broker)
│   ├── Dockerfile        imagem de produção, gerada pelo Rails
│   ├── Dockerfile.dev    imagem de desenvolvimento e teste, usada pelo Compose
│   ├── app/modules/      channels/ conversations/ routing/ agents/ audit/ admin/
│   ├── config/           database.yml, queue.yml, cable.yml, cache.yml
│   ├── db/               migrate/, structure.sql
│   ├── lib/              contract/, broker/, tasks/structure_privileges.rake
│   └── spec/             RSpec
├── contracts/            contrato entre Core, Broker e agente
├── agent_mock/           Python: pyproject.toml, src/, tests/
├── channel_simulator/    Python: pyproject.toml, src/, tests/
├── experiment/           k6 e análise do experimento
├── infra/
│   ├── postgres/init/    criação dos papéis e dos bancos
│   └── redpanda/         criação dos tópicos
├── documents/
├── .env.example          nomes dos papéis, dos bancos e das variáveis; valores no .env
├── .gitattributes        final de linha LF nos scripts e Dockerfiles
├── compose.yaml
└── README.md
```

- **Módulos como namespaces.** O Rails acrescenta ao autoload os diretórios sob `app`, e os diretórios funcionam como namespaces: `core/app/modules/routing/` define constantes em `Routing`, sem configuração adicional. Os módulos são `Channels`, `Conversations`, `Routing`, `Agents`, `Audit` e `Admin`.
- **Credenciais.** Ficam no `.env` da raiz, criado a partir do `.env.example`; o `.env` não é versionado.
- **Final de linha.** O `.gitattributes` força LF nos `.sh`, nos Dockerfiles e em `core/bin/*`: com `core.autocrlf=true` no Windows, um script com CRLF falharia dentro do contêiner.

### App Rails

| Item | Definição |
| - | - |
| Versão | Rails 8.1 (8.1.4.1), Ruby 3.4 (3.4.12) |
| Tipo | App completo, não só API: chat, painel e admin são telas Hotwire |
| Banco | PostgreSQL |
| Active Storage | Ligado: o Action Mailbox guarda o e-mail original por ele |
| Testes | RSpec (`rspec-rails` 8.1) |
| Fora do app | Kamal, framework de teste padrão, CI do GitHub, devcontainer, RuboCop, Brakeman e bundler-audit |

**Imagem do Core.** O `core/Dockerfile.dev` parte de `ruby:3.4-slim`, instala o `postgresql-client-18` do repositório oficial PGDG e as gems do `Gemfile.lock`. O `pg_dump` precisa ser da mesma versão do servidor para gerar o `db/structure.sql`, e o cliente do Debian da imagem base é de versão anterior. O Compose monta `core/` como volume, e as mudanças no código valem sem reconstruir a imagem. O `core/Dockerfile`, gerado pelo Rails, é o de produção: define `RAILS_ENV=production` e exclui as gems de desenvolvimento e teste.

### Solid Queue, Solid Cable e Solid Cache no banco do app

| Peça | Configuração |
| - | - |
| Solid Queue 1.7 | Banco único, conforme a seção "Single database configuration" do README; adaptador de jobs em desenvolvimento, teste e produção |
| Solid Cable 4.1 | Banco do app em desenvolvimento e produção, com polling de 0,1 s e retenção de 1 dia; adaptador `test` em teste |
| Solid Cache 1.0 | Pool do `ActiveRecord::Base` em desenvolvimento e produção; `null_store` em teste |

- As tabelas das três peças ficam em uma migração normal, `db/migrate/20261115120000_create_solid_tables.rb`, e o `database.yml` tem uma só entrada por ambiente.
- O README do Solid Queue recomenda um banco separado, mas admite o banco único. O Cloudesk usa o banco único de propósito: é o que torna atômica a gravação da mensagem com o job de webhook.
- No pool principal, as leituras e escritas do cache participam da transação em curso: uma escrita de cache numa transação desfeita some com ela.

### Papéis e bancos

O script `infra/postgres/init/01-roles-and-databases.sh` roda na primeira inicialização do contêiner do Postgres, com o diretório de dados vazio, e cria:

- `cloudesk_owner`, dono das tabelas, para migrações e seeds;
- `cloudesk_app`, para os processos da aplicação e os testes;
- os bancos `cloudesk_development` e `cloudesk_test`, com o papel dono como dono.

Os dois papéis nascem sem superusuário, `BYPASSRLS`, `CREATEROLE` e `CREATEDB`. O superusuário da imagem serve só para rodar o script. Nomes e senhas chegam por variável de ambiente, a partir do `.env`; o `database.yml` lê `DB_USERNAME` e `DB_PASSWORD`, que o Compose preenche com as credenciais do papel da aplicação.

**Schema com permissões.** O Rails gera o `db/structure.sql` com `pg_dump` sem privilégios, e em banco vazio o `db:migrate` carrega esse arquivo em vez de rodar as migrações. A task `core/lib/tasks/structure_privileges.rake` estende o `db:schema:dump` e acrescenta ao arquivo os `GRANT` e `REVOKE` do banco: um banco carregado do schema fica com as mesmas permissões de um banco migrado. Os nomes dos papéis ficam gravados no arquivo e por isso são fixos.

**Banco de teste.** É montado com `RAILS_ENV=test bin/rails db:migrate` e o papel dono, que em banco vazio carrega o `structure.sql` com as permissões. O RSpec não usa `maintain_test_schema!`, porque o papel da aplicação não cria tabelas, e o `db:test:prepare` não é usado, porque apaga e recria o banco, o que exigiria `CREATEDB`.

### Docker Compose

| Serviço | Imagem | Papel |
| - | - | - |
| `postgres` | `postgres:18` | Banco único, com volume em `/var/lib/postgresql` e o script de papéis |
| `redpanda` | `redpanda:v26.2.7` | Kafka de um nó, modo `dev-container`, 1 núcleo; listener interno na 9092 e externo na 19092 |
| `redpanda-init` | `redpanda:v26.2.7` | Cria os tópicos e termina |
| `mailpit` | `axllent/mailpit` | SMTP na 1025, API e interface na 8025, webhook para o Core |
| `web` | `cloudesk-core:dev` | Rails (Puma) na 3000 |
| `jobs-default` | `cloudesk-core:dev` | Solid Queue: filas internas e tarefas recorrentes |
| `jobs-webhooks` | `cloudesk-core:dev` | Solid Queue: só a fila `webhooks` |
| `broker-web` | `cloudesk-core:dev` | Endpoint Rack do Broker (Puma) |
| `broker-consumer` | `cloudesk-core:dev` | `karafka server` |
| `channel-simulator` | `cloudesk-channel-simulator:dev` | Simulador de canais na 8080 |
| `agent-mock` | `cloudesk-agent-mock:dev` | Agente mock |

- Os serviços Rails compartilham o bloco `x-rails` por âncora YAML, com a imagem, o ambiente (`rails-environment`) e os volumes, e mudam só o `command`.
- Portas publicadas no host: 3000 (`web`), 3001 (`broker-web`), 8080 (`channel-simulator`), 1025 e 8025 (`mailpit`) e 19092 (`redpanda`). O Postgres não fica exposto.
- O PostgreSQL 18 usa o volume em `/var/lib/postgresql`, e não em `/var/lib/postgresql/data`: a partir da versão 18, a imagem oficial guarda os dados num diretório por versão.

### Tópicos Kafka

| Tópico | Partições | Uso |
| - | - | - |
| `agent.inbound` | 6 | Eventos do Core para o agente |
| `agent.outbound` | 6 | Ações do agente para o Core |
| `agent.dlq` | Padrão do cluster | Ações que o `broker-consumer` não consegue processar |

- O script `infra/redpanda/create-topics.sh` cria os tópicos com `rpk topic create --if-not-exists`, com fator de replicação 1, porque o ambiente tem um único nó.
- O script define `message.timestamp.type=LogAppendTime` em `agent.inbound`: o timestamp do registro é o horário de gravação no Kafka, que o agente devolve na ação (`documents/fases/04-contrato-de-integracao.md`).
- As partições limitam o paralelismo: até 6 consumidores por grupo em cada tópico.
- A criação fica num script, e não no Karafka, porque o agente em Python também depende dos tópicos, e o Karafka não cria o tópico de DLQ.

### Python

`agent_mock/` e `channel_simulator/` são projetos independentes, cada um com `pyproject.toml`, código em `src/` e testes em `tests/`, instalados com `pip`. Os dois exigem Python 3.13 ou superior, e o pytest vem no extra `test`. Cada um tem imagem própria no Compose.

## O que o sistema garante

- O ambiente completo sobe com o Docker Compose, sem dependências na máquina além do Docker.
- Jobs, tempo real e cache usam o mesmo banco e a mesma conexão do app.
- A aplicação conecta ao Postgres com um papel sem privilégios de dono, superusuário ou `BYPASSRLS`.
- Um banco carregado do `structure.sql` tem as mesmas permissões de um banco migrado.
- Os tópicos existem com as partições e a configuração de timestamp esperadas, e o script pode rodar de novo sem falhar.

## Como compõe os entregáveis do projeto

| Entregável | O que esta parte entrega |
| - | - |
| Plataforma self-hosted, empacotada em Docker Compose | O Compose com todos os serviços, as imagens e os scripts de inicialização |
| Integração com o atendente por webhooks e broker | O Redpanda, os tópicos e os processos do Broker e do agente no Compose |
| Recebimento multicanal simulado | O Mailpit e o serviço do simulador de canais |
| Documentação: instalação e execução | O caminho único de execução: `.env` a partir do `.env.example` e `docker compose up` |

### No experimento técnico

| Hipótese | Contribuição |
| - | - |
| H1 · 250 msg/s por 15 min | A escala por papel: `web`, `jobs-webhooks` e Broker escalam por réplicas, e as 6 partições limitam o paralelismo dos consumidores |
| H3 · nada perdido nem duplicado | O banco único torna possível o outbox implícito; os processos separados permitem `docker restart` no Broker e `docker kill` num worker sem derrubar o resto |
| H2 e H4 | O ambiente medido é o do Compose, na mesma máquina do gerador de carga |

## Diferenciais

Nenhum diferencial é implementado aqui. O cockpit operacional (diferencial 2) depende de Prometheus e Grafana, que não estão no Compose.

## Limitações

- **Um único nó.** Um PostgreSQL e um Redpanda, sem réplica: o ambiente não mede alta disponibilidade.
- **O PostgreSQL concentra todo o estado.** Domínio, jobs, tempo real e cache disputam o mesmo banco, o gargalo esperado de escala.
- **Sem pooler de conexões.** O número de processos é limitado pelas conexões do Postgres.
- **Hardware local.** O ambiente roda na máquina de desenvolvimento; no Windows, os contêineres rodam sobre WSL2. Os valores medidos não se transferem para produção.
- **Imagem de produção sem o contrato.** O `core/Dockerfile` é construído com o contexto `./core` e não copia `contracts/`; a imagem de produção precisa de um contexto adicional de build. O Compose usa o `Dockerfile.dev`, com a pasta como volume.
- **Polling do Solid Cable.** O padrão é consultar o banco a cada 0,1 s e reter as mensagens por 1 dia; o README indica que poucos minutos de retenção bastam para a maioria dos apps.
- **Sem observabilidade no Compose.** Prometheus e Grafana fazem parte da arquitetura, mas não estão no Compose.

## Operação

**Ordem de uso:**

1. `.env` a partir do `.env.example`, com os segredos preenchidos;
2. `docker compose up -d`;
3. migrações e seeds no contêiner `web`, com o papel dono;
4. banco de teste com `RAILS_ENV=test bin/rails db:migrate` e o papel dono.

### Verificação

| Arquivo | O que comprova |
| - | - |
| `core/spec/jobs/smoke_job_spec.rb` | O adaptador de jobs é o Solid Queue, com a mesma conexão do app; o `SmokeJob` é gravado em `solid_queue_jobs` e executado pelo caminho do worker |
| `core/spec/tenancy/brand_isolation_spec.rb` | A aplicação conecta com o papel da aplicação, sem superusuário, sem `BYPASSRLS` e sem ser dona |
| `core/spec/tenancy/owner_role_spec.rb` | O papel dono não tem superusuário nem `BYPASSRLS` |
| `agent_mock/tests/`, `channel_simulator/tests/` | Os projetos Python instalam e o pytest roda |

No Compose, `docker compose ps` mostra os serviços no ar, `redpanda-init` termina com sucesso e `rpk topic list` mostra os três tópicos.

## Relação com as outras partes

| Parte | Relação |
| - | - |
| Banco multi-marca (F1) | Usa os papéis e acrescenta as tabelas de domínio, o RLS e as permissões, que entram no `structure.sql` pela task de privilégios |
| Núcleo transacional (F2) | Usa o Solid Queue no banco do app para o outbox implícito |
| Contrato (F3) | Chega aos serviços pelo volume `/contracts`; usa o `LogAppendTime` de `agent.inbound` |
| Canais (F4) | Usa o Mailpit e o Active Storage ligado |
| Saída para o Broker (F7) | Roda no `jobs-webhooks` |
| Broker (F9) | Roda no `broker-web` e no `broker-consumer`, com os tópicos criados aqui |
| Robustez e escala (F15) | Dimensiona réplicas, pool e polling sobre este ambiente |

## Fontes

- `documents/arquitetura.md`, seções "Arquitetura", "Componentes", "Processos" e "Decisões de design"
- [Rails Guides · Autoloading and Reloading Constants](https://guides.rubyonrails.org/autoloading_and_reloading_constants.html)
- [Rails Guides · Action Mailbox Basics](https://guides.rubyonrails.org/action_mailbox_basics.html)
- [Solid Queue · README](https://github.com/rails/solid_queue)
- [Solid Cable · README](https://github.com/rails/solid_cable)
- [Solid Cache · README](https://github.com/rails/solid_cache)
- [PostgreSQL · imagem oficial no Docker Hub](https://hub.docker.com/_/postgres)
- [PostgreSQL 18 · Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
- Código do ActiveRecord 8.1.4.1 (`PostgreSQLDatabaseTasks#structure_dump`, `DatabaseTasks#initialize_database` e `purge`)

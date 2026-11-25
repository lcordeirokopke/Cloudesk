# Core e Broker

App Rails 8.1 do Cloudesk, com o código do Broker. Entradas: `config.ru` (`web`), `broker.ru` (`broker-web`), `karafka.rb` (`broker-consumer`) e `metrics.ru` (`metrics`). O Broker fica em `lib/broker/` e roda sem Rails e sem banco.

Módulos em `app/modules/`:

- `channels/`: entrada e entrega por WhatsApp, chat e e-mail, e limite de taxa.
- `conversations/`: entrada, resposta, escalação, timeout, memória e linha do tempo.
- `routing/`: classificação, regras, filas e distribuição.
- `agents/`: webhook ao Broker, API de ações e contexto do agente.
- `audit/`: comando transacional e envelope dos eventos.
- `admin/`: edição de filas, equipes, atendentes e regras, e DLQ.
- `observability/`: métricas do serviço `metrics`.

Testes, da raiz do repositório e com o banco de teste preparado: `docker compose exec -e RAILS_ENV=test web bundle exec rspec`

Instalação e execução: [README](../README.md). Arquitetura: [documents/arquitetura.md](../documents/arquitetura.md).

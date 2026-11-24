# Medida de dimensionamento

O roteiro `measure_idle.sh` mede o custo do polling do Solid Queue com os serviços ociosos, as conexões ao Postgres por processo e uma carga leve com os papéis escaláveis em duas réplicas. Os números sustentam os valores de threads, réplicas, pool e `max_connections` registrados em `documents/fases/16-robustez-e-escala.md`.

## Pré-requisitos

- Ambiente do Compose com o `.env` preenchido e o banco com as seeds.
- Bash, `curl` e `awk` no host (o Git Bash serve no Windows).
- Prometheus em `localhost:9090` (serviço `prometheus` do Compose).

## Execução

Da raiz do repositório:

```bash
experiment/scale/measure_idle.sh
```

O roteiro sobe o ambiente com `CLOUDESK_LOAD_PROFILE=1` e segue estes passos:

1. Mede o TPS e as conexões ociosas com o `jobs-webhooks` em 1, 2 e 4 réplicas e depois com o `jobs-default` em 2 e 4. Antes de cada leitura, espera `IDLE_SECONDS`.
2. Conta as conexões por contêiner, cruzando o `client_addr` do `pg_stat_activity` com o IP de cada contêiner.
3. Roda `channel-simulator send --channel all` com `web`, `jobs-webhooks`, `broker-web`, `broker-consumer` e `agent-mock` em 2 réplicas. Durante a carga, anota o máximo de conexões, de jobs prontos e de lag.
4. Volta a uma réplica por serviço e imprime as tabelas e o comando da `robustness:check` para o início da carga.

| Variável | Padrão | Uso |
| - | - | - |
| `IDLE_SECONDS` | `120` | Espera ociosa antes de cada leitura |
| `LOAD_COUNT` | `4800` | Mensagens da carga leve |
| `LOAD_RATE` | `80` | Mensagens por segundo da carga leve |
| `REPLICAS` | `1 2 4` | Réplicas medidas por worker |

As métricas lidas no Prometheus são `pg_stat_database_xact_commit` e `pg_stat_activity_count` (do `postgres-exporter`), `cloudesk_solid_queue_jobs` (do serviço `metrics`) e `redpanda_kafka_consumer_group_lag_sum` (do Redpanda).

## Onde ficam os números

A saída do roteiro vai para a seção de medidas de `documents/fases/16-robustez-e-escala.md`.

#!/usr/bin/env bash
# Medida do dimensionamento da F15: custo ocioso do polling do Solid Queue por réplica, conexões ao
# Postgres por processo e uma carga leve com os papéis escaláveis em 2 réplicas. Roda da raiz do
# repositório, com o ambiente do Compose e o .env preenchido. Lê o Prometheus em localhost:9090 e o
# Postgres pelo psql do contêiner postgres. Imprime as tabelas em texto; os números vão para
# documents/fases/16-robustez-e-escala.md.
#
#   experiment/scale/measure_idle.sh
#
# Variáveis (padrões entre parênteses):
#   IDLE_SECONDS  espera ociosa antes de cada leitura (120); a taxa usa a janela de 1 min do Prometheus
#   LOAD_COUNT    mensagens da carga leve (4800)
#   LOAD_RATE     mensagens por segundo da carga leve (80)
#   REPLICAS      lista de réplicas medidas por worker ("1 2 4")
set -euo pipefail

IDLE_SECONDS="${IDLE_SECONDS:-120}"
LOAD_COUNT="${LOAD_COUNT:-4800}"
LOAD_RATE="${LOAD_RATE:-80}"
REPLICAS="${REPLICAS:-1 2 4}"
PROMETHEUS="${PROMETHEUS:-http://localhost:9090}"
DATABASE="${DB_DEVELOPMENT_NAME:-cloudesk_development}"

export CLOUDESK_LOAD_PROFILE=1

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Valor escalar de uma consulta instantânea ao Prometheus (vazio sem resultado).
prom() {
  curl -s "$PROMETHEUS/api/v1/query" --data-urlencode "query=$1" |
    grep -o '"value":\[[^]]*\]' | head -1 | sed -E 's/.*,"([^"]*)"\]/\1/'
}

tps() { prom "sum(rate(pg_stat_database_xact_commit{datname=\"$DATABASE\"}[1m]))"; }
connections() { prom "sum(pg_stat_activity_count{datname=\"$DATABASE\"})"; }

psql_query() {
  docker compose exec -T postgres sh -c "psql -U \"\$POSTGRES_USER\" -d \"$DATABASE\" -At -F ' ' -c \"$1\""
}

scale() {
  docker compose up -d --scale "web=$1" --scale "jobs-webhooks=$2" --scale "jobs-default=$3" \
    --scale "broker-web=$4" --scale "broker-consumer=$5" --scale "agent-mock=$6" >/dev/null 2>&1
}

# Conexões ao banco por contêiner: client_addr do pg_stat_activity cruzado com o IP de cada contêiner.
connections_by_container() {
  local ips
  ips="$(docker compose ps -q | xargs docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{.Name}}')"
  psql_query "select host(client_addr), count(*) from pg_stat_activity where datname = '$DATABASE' and client_addr is not null group by 1 order by 1" |
    while read -r ip count; do
      name="$(printf '%s\n' "$ips" | awk -v ip="$ip" '$1 == ip { sub("^/", "", $2); print $2 }')"
      printf '  %-40s %s\n' "${name:-$ip}" "$count"
    done
}

log "subindo o ambiente com CLOUDESK_LOAD_PROFILE=1"
docker compose up -d >/dev/null 2>&1

idle_rows=()
for n in $REPLICAS; do
  log "ocioso: jobs-webhooks=$n, jobs-default=1; espera de ${IDLE_SECONDS}s"
  scale 1 "$n" 1 1 1 1
  sleep "$IDLE_SECONDS"
  idle_rows+=("jobs-webhooks=$n jobs-default=1 $(tps) $(connections)")
done
for n in $REPLICAS; do
  [ "$n" = "1" ] && continue
  log "ocioso: jobs-webhooks=1, jobs-default=$n; espera de ${IDLE_SECONDS}s"
  scale 1 1 "$n" 1 1 1
  sleep "$IDLE_SECONDS"
  idle_rows+=("jobs-webhooks=1 jobs-default=$n $(tps) $(connections)")
done

log "conexões por contêiner, uma réplica por serviço"
scale 1 1 1 1 1 1
sleep 30
per_container="$(connections_by_container)"

log "carga leve: $LOAD_COUNT mensagens a $LOAD_RATE msg/s, papéis escaláveis em 2 réplicas"
scale 2 2 1 2 2 2
sleep 30
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose exec -T channel-simulator channel-simulator send --channel all --count "$LOAD_COUNT" --rate "$LOAD_RATE" >/dev/null &
sender=$!
max_connections=0
max_backlog=0
max_lag=0
while kill -0 "$sender" 2>/dev/null; do
  c="$(connections)"; b="$(prom 'sum(cloudesk_solid_queue_jobs{state="ready"})')"
  l="$(prom 'sum(redpanda_kafka_consumer_group_lag_sum)')"
  max_connections="$(awk -v a="$max_connections" -v b="${c:-0}" 'BEGIN { print (b > a ? b : a) }')"
  max_backlog="$(awk -v a="$max_backlog" -v b="${b:-0}" 'BEGIN { print (b > a ? b : a) }')"
  max_lag="$(awk -v a="$max_lag" -v b="${l:-0}" 'BEGIN { print (b > a ? b : a) }')"
  sleep 5
done
wait "$sender" || log "o simulador terminou com erro"
load_tps="$(prom "max_over_time(sum(rate(pg_stat_database_xact_commit{datname=\"$DATABASE\"}[1m]))[5m:15s])")"
per_container_load="$(connections_by_container)"

log "voltando a uma réplica por serviço"
scale 1 1 1 1 1 1

printf '\nTPS e conexões ociosos (Postgres, %s)\n' "$DATABASE"
printf '  %-40s %12s %12s\n' "réplicas" "TPS" "conexões"
for row in "${idle_rows[@]}"; do
  read -r webhooks default rate total <<< "$row"
  printf '  %-40s %12.1f %12s\n' "$webhooks $default" "$rate" "$total"
done

printf '\nConexões por contêiner, ociosas, uma réplica por serviço\n%s\n' "$per_container"
printf '\nCarga leve (%s mensagens a %s msg/s, desde %s)\n' "$LOAD_COUNT" "$LOAD_RATE" "$since"
printf '  %-40s %12s\n' "máximo de conexões" "$max_connections"
printf '  %-40s %12s\n' "máximo de jobs prontos" "$max_backlog"
printf '  %-40s %12s\n' "máximo de lag (soma dos grupos)" "$max_lag"
printf '  %-40s %12.1f\n' "TPS máximo (janela de 1 min)" "${load_tps:-0}"
printf '\nConexões por contêiner ao fim da carga\n%s\n' "$per_container_load"
printf '\nConferência sem duplicação: docker compose run --rm web bin/rails robustness:check SINCE=%s\n' "$since"

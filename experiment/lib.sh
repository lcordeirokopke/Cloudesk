# Funções do roteiro do experimento (experiment/run.sh). Rodam da raiz do repositório, sempre no projeto
# Compose cloudesk-experiment, que é fixo: nenhum comando recebe o projeto por parâmetro.
set -euo pipefail

# Git Bash: os caminhos de contêiner (/results, /app) seguem sem conversão.
export MSYS_NO_PATHCONV=1
# Perfil de carga e latência artificial do agente em todo comando do Compose.
export CLOUDESK_LOAD_PROFILE=1
export AGENT_LATENCY_MS=200

PROJECT=cloudesk-experiment
K6_CONTAINER=cloudesk-experiment-k6
RESULTS=experiment/results
PROMETHEUS=http://localhost:9090
MEMORY_LIMIT_KB=512000
ERROR_LIMIT_PERCENT=20
# Guarda de erros: desligada só por experiment/run.sh meta sem-guarda-de-erros; fica em conditions.json.
ERROR_GUARD=true
SETTLE_SECONDS=25
H1_CHECK_SECONDS=300

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "erro: $*"; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

dc() { docker compose -p cloudesk-experiment -f compose.yaml -f experiment/compose.yaml "$@"; }
analysis() { dc --profile experiment run --rm --no-deps -T analysis cloudesk-experiment "$@"; }

# Texto como string JSON, com as quebras de linha escapadas.
json() {
  printf '%s' "$1" | tr -d '\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g' |
    awk 'BEGIN { printf "\"" } NR > 1 { printf "\\n" } { printf "%s", $0 } END { printf "\"" }'
}

# Sessão

load_session() {
  SESSION="${SESSION:-}"
  if [ -z "$SESSION" ]; then
    [ -f "$RESULTS/.session" ] || die "nenhuma sessão; rode experiment/run.sh preflight"
    SESSION="$(cat "$RESULTS/.session")"
  fi
  SESSION_DIR="$RESULTS/$SESSION"
  [ -d "$SESSION_DIR" ] || die "sessão $SESSION não encontrada em $RESULTS"
  # shellcheck disable=SC1091
  . "$SESSION_DIR/replicas.env"
}

save_replicas() {
  cat > "$SESSION_DIR/replicas.env" <<EOF
WEB=$WEB
JOBS_WEBHOOKS=$JOBS_WEBHOOKS
JOBS_DEFAULT=$JOBS_DEFAULT
BROKER_WEB=$BROKER_WEB
BROKER_CONSUMER=$BROKER_CONSUMER
AGENT_MOCK=$AGENT_MOCK
TAXA_H3=${TAXA_H3:-}
EOF
}

# Número da execução no ambiente: entra nos telefones do WhatsApp e volta a 0 quando o ambiente é recriado.
next_stage_number() {
  local file="$SESSION_DIR/raw/environment" number
  mkdir -p "$SESSION_DIR/raw"
  number=$(( $(cat "$file" 2>/dev/null || echo 0) + 1 ))
  echo "$number" > "$file"
  STAGE_NUMBER="$number"
}

# Pasta da próxima execução da etapa: <etapa>-<n>.
new_stage_dir() {
  local stage="$1" n=1
  while [ -d "$SESSION_DIR/$stage-$n" ]; do n=$((n + 1)); done
  RUN="$stage-$n"
  STAGE_DIR="$SESSION_DIR/$RUN"
  mkdir -p "$STAGE_DIR/raw"
}

# Prometheus

# Valor escalar de uma consulta instantânea; 0 sem resultado.
prom() {
  local value
  value="$(curl -s "$PROMETHEUS/api/v1/query" --data-urlencode "query=$1" |
    grep -o '"value":\[[^]]*\]' | head -1 | sed -E 's/.*,"([^"]*)"\]/\1/' || true)"
  printf '%s' "${value:-0}"
}

backlog_jobs() { prom 'sum(cloudesk_solid_queue_jobs{queue=~"webhooks|channels|default",state=~"ready|claimed"})'; }
backlog_scheduled() { prom 'sum(cloudesk_solid_queue_jobs{queue=~"webhooks|channels",state="scheduled"})'; }
backlog_lag() { prom 'sum(redpanda_kafka_consumer_group_lag_sum{redpanda_group=~"cloudesk-agent|cloudesk-broker"})'; }

# Espera o backlog zerar em duas amostras seguidas, a cada 15 s, até o limite em segundos.
drain() {
  local limit="$1" started zero=0 jobs lag scheduled
  started="$(date +%s)"
  while true; do
    jobs="$(backlog_jobs)"; lag="$(backlog_lag)"; scheduled="$(backlog_scheduled)"
    if awk -v j="$jobs" -v l="$lag" -v s="$scheduled" 'BEGIN { exit !(j <= 5 && l == 0 && s == 0) }'; then
      zero=$((zero + 1))
    else
      zero=0
    fi
    log "drenagem: jobs $jobs, lag $lag, agendados $scheduled"
    [ "$zero" -ge 2 ] && return 0
    [ $(( $(date +%s) - started )) -ge "$limit" ] && return 1
    sleep 15
  done
}

# Ambiente

running() { [ -n "$(dc ps -q "$1" 2>/dev/null)" ]; }

wait_ready() {
  local started all ok
  started="$(date +%s)"
  log "esperando a prontidão"
  while true; do
    ok=1
    [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/up || true)" = "200" ] || ok=0
    for all in $(dc ps -q broker-web); do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "$all")" = "healthy" ] || ok=0
    done
    [ "$(dc exec -T redpanda rpk group describe cloudesk-agent cloudesk-broker 2>/dev/null |
      grep -cE '^STATE +Stable' || true)" = "2" ] || ok=0
    all="$(curl -s "$PROMETHEUS/api/v1/targets?state=active" || true)"
    [[ "$all" == *'"health":"up"'* ]] || ok=0
    [[ "$all" == *'"health":"down"'* || "$all" == *'"health":"unknown"'* ]] && ok=0
    [ "$ok" = "1" ] && { log "ambiente pronto"; return 0; }
    [ $(( $(date +%s) - started )) -ge 300 ] && die "o ambiente não ficou pronto em 5 min"
    sleep 5
  done
}

recreate() {
  log "recriando o ambiente $PROJECT (volumes do projeto apagados)"
  docker rm -f "$K6_CONTAINER" >/dev/null 2>&1 || true
  dc --profile experiment down -v --remove-orphans >/dev/null 2>&1
  mkdir -p "$SESSION_DIR/raw"
  echo 0 > "$SESSION_DIR/raw/environment"
  dc up -d --wait postgres redpanda mailpit >/dev/null 2>&1 || die "postgres, redpanda ou mailpit não subiram"
  dc up -d redpanda-init >/dev/null 2>&1
  # O runner gera o secret_key_base no volume antes de as réplicas do web subirem: todas usam o mesmo.
  dc run --rm --no-deps -T web sh -c \
    'DB_USERNAME="$DB_OWNER_USERNAME" DB_PASSWORD="$DB_OWNER_PASSWORD" bin/rails db:migrate db:seed &&
     bin/rails runner Rails.application.secret_key_base' \
    > "$SESSION_DIR/raw/migrate.log" 2>&1 || die "db:migrate ou db:seed falhou ($SESSION_DIR/raw/migrate.log)"
  [ -z "$(git status --porcelain core/db/structure.sql)" ] || die "core/db/structure.sql difere do repositório; levar ao usuário"
  dc up -d --scale grafana=0 --scale "web=$WEB" --scale "jobs-webhooks=$JOBS_WEBHOOKS" \
    --scale "jobs-default=$JOBS_DEFAULT" --scale "broker-web=$BROKER_WEB" \
    --scale "broker-consumer=$BROKER_CONSUMER" --scale "agent-mock=$AGENT_MOCK" \
    > "$SESSION_DIR/raw/up.log" 2>&1 || die "o ambiente não subiu ($SESSION_DIR/raw/up.log)"
  wait_ready
}

# Aquecimento

# Lojistas de chat com resposta da IA recebida a partir do horário informado.
chat_answered_since() {
  dc exec -T channel-simulator sh -c 'cat /app/data/received.jsonl 2>/dev/null || true' | awk -v since="$1" '
    /"channel":"chat"/ && /"author":"ai"/ {
      match($0, /"received_at":"[^"]+"/); at = substr($0, RSTART + 15, RLENGTH - 16)
      match($0, /"recipient":"[^"]+"/); who = substr($0, RSTART + 13, RLENGTH - 14)
      if (at >= since) seen[who] = 1
    }
    END { for (who in seen) total++; print total + 0 }'
}

warmup_phase() {
  local phase="$1" shoppers="$2"
  next_stage_number
  dc --profile experiment run --rm --no-deps -T -e PHASE="$phase" -e SHOPPERS="$shoppers" -e SESSION="$SESSION" \
    -e RUN="aquecimento-$STAGE_NUMBER" -e STAGE_NUMBER="$STAGE_NUMBER" k6 run --quiet --log-format raw \
    --console-output "/results/$SESSION/raw/aquecimento-$STAGE_NUMBER.jsonl" /scripts/warmup.js \
    > "$SESSION_DIR/raw/aquecimento-$STAGE_NUMBER.log" 2>&1 || die "o aquecimento ($phase) falhou"
}

warmup_second() {
  local shoppers="$1" since answered
  since="$(now)"
  warmup_phase second "$shoppers"
  drain 180 || die "o aquecimento não drenou em 3 min"
  answered="$(chat_answered_since "$since")"
  log "aquecimento: $answered de $shoppers lojistas de chat com resposta recebida"
  [ "$answered" -ge "$shoppers" ]
}

warmup() {
  local shoppers="$1"
  log "aquecimento com $shoppers lojistas de chat"
  warmup_phase register "$shoppers"
  sleep 5
  warmup_second "$shoppers" && return 0
  log "reiniciando o channel-simulator para assinar de novo os streams"
  dc restart channel-simulator >/dev/null 2>&1
  sleep 15
  warmup_second "$shoppers" || die "faltam respostas de chat no simulador depois do reinício"
}

# Amostras e guardas

memory_available_kb() { dc exec -T postgres awk '/MemAvailable/ { print $2 }' /proc/meminfo; }

sampler() {
  local file="$1" at
  while true; do
    at="$(now)"
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' 2>/dev/null | sed "s/^/$at,/" >> "$file" || true
    printf '%s,_memavailable,,%s\n' "$at" "$(memory_available_kb 2>/dev/null || echo 0)" >> "$file"
    sleep 7
  done
}

# Motivo da parada pela guarda, ou vazio: duas amostras seguidas com menos de 500 MB, ou mais de 20%
# de respostas diferentes de 200 no último minuto (só com a guarda de erros ligada).
guard_reason() {
  local since
  if [ "$(grep ',_memavailable,' "$STAGE_DIR/raw/docker-stats.csv" 2>/dev/null | tail -2 |
    awk -F, -v limit="$MEMORY_LIMIT_KB" '$4 > 0 && $4 < limit { low++ } END { print low + 0 }')" = "2" ]; then
    echo "memória disponível abaixo de 500 MB em duas amostras seguidas"
    return 0
  fi
  [ "$ERROR_GUARD" = "true" ] || return 0
  since="$(date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%S.%3NZ)"
  tail -n 40000 "$STAGE_DIR/raw/sent.jsonl" 2>/dev/null | awk -v since="$since" -v limit="$ERROR_LIMIT_PERCENT" '
    match($0, /"sent_at":"[^"]+"/) {
      if (substr($0, RSTART + 11, RLENGTH - 12) < since) next
      total++
      if ($0 !~ /"status":200[,}]/) bad++
    }
    END { if (total >= 20 && bad * 100 > total * limit) printf "%d de %d respostas diferentes de 200 no último minuto", bad, total }'
}

# Dados brutos e condições

# Entradas e saídas da espera moderna do Windows (eventos 506 e 507 do Kernel-Power) desde o horário
# informado, mais a última anterior, porque a máquina pode já estar em espera. Lista JSON, ou null
# quando o host não tem PowerShell.
host_standby() {
  local lines
  command -v powershell.exe >/dev/null 2>&1 || { printf null; return 0; }
  lines="$(powershell.exe -NoProfile -Command '
    Get-WinEvent -FilterHashtable @{LogName="System"; ProviderName="Microsoft-Windows-Kernel-Power"; Id=506,507; StartTime=(Get-Date).AddHours(-24)} -ErrorAction SilentlyContinue |
      Sort-Object TimeCreated | ForEach-Object { $_.TimeCreated.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + "," + $_.Id }' 2>/dev/null | tr -d '' || true)"
  printf '%s
' "$lines" | awk -F, -v since="$1" '
    $2 != 506 && $2 != 507 { next }
    { item = sprintf("{\"at\": \"%s\", \"event\": \"%s\"}", $1, ($2 == 506 ? "enter" : "exit")) }
    $1 < since { before = item; next }
    { list = list (list == "" ? "" : ", ") item }
    END { printf "[%s%s%s]", before, (before != "" && list != "" ? ", " : ""), list }'
}

dlq_messages() {
  dc exec -T redpanda rpk topic describe agent.dlq -p 2>/dev/null |
    awk '$1 ~ /^[0-9]+$/ { total += $NF } END { print total + 0 }'
}

replicas_json() {
  printf '{"web": %s, "jobs-webhooks": %s, "jobs-default": %s, "broker-web": %s, "broker-consumer": %s, "agent-mock": %s}' \
    "$WEB" "$JOBS_WEBHOOKS" "$JOBS_DEFAULT" "$BROKER_WEB" "$BROKER_CONSUMER" "$AGENT_MOCK"
}

# Variáveis não secretas dos contêineres que definem o comportamento da carga.
settings() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' cloudesk-experiment-web-1 cloudesk-experiment-agent-mock-1 2>/dev/null |
    grep -E '^(RAILS_ENV|RAILS_MAX_THREADS|RUBY_YJIT_ENABLE|CLOUDESK_LOAD_PROFILE|AGENT_LATENCY_MS|AGENT_CONCURRENCY|AGENT_FAILURE_MODE|AGENT_FAILURE_RATE|AGENT_FAILURE_DELAY_MS|AGENT_MEMORY_WINDOW_DAYS)=' |
    sort -u || true
  echo "POSTGRES_MAX_CONNECTIONS=${POSTGRES_MAX_CONNECTIONS:-200 (padrão)}"
}

image_versions() {
  dc --profile experiment config --images | tr -d '\r' | sort -u | while read -r image; do
    printf '%s %s\n' "$image" "$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null | cut -c8-19)"
  done
}

other_containers() { docker ps --format '{{.Names}}' | grep -v '^cloudesk-experiment-' || true; }

# Variáveis lidas: STAGE, RUN, KIND, RATE, DURATION, STATUS, REASON, STARTED_AT, STOPPED_AT, DRAINED,
# CAPTURED_UNTIL, DLQ_BEFORE, DLQ_AFTER, HOST_STANDBY, STAGE_NUMBER e o ENVIRONMENT_JSON do início.
write_conditions() {
  cat > "$STAGE_DIR/conditions.json" <<EOF
{
  "session": $(json "$SESSION"),
  "stage": $(json "$STAGE"),
  "run": $(json "$RUN"),
  "kind": $(json "$KIND"),
  "rate": ${RATE:-0},
  "duration_seconds": ${DURATION:-0},
  "stage_number": ${STAGE_NUMBER:-0},
  "status": $(json "$STATUS"),
  "reason": $(if [ -n "$REASON" ]; then json "$REASON"; else printf null; fi),
  "k6_started_at": $(json "$STARTED_AT"),
  "load_stopped_at": $(if [ -n "$STOPPED_AT" ]; then json "$STOPPED_AT"; else printf null; fi),
  "k6_exit_code": ${K6_EXIT:-null},
  "drained": ${DRAINED:-false},
  "captured_until": $(json "${CAPTURED_UNTIL:-}"),
  "dlq_before": ${DLQ_BEFORE:-0},
  "dlq_after": ${DLQ_AFTER:-0},
  "error_guard": $ERROR_GUARD,
  "replicas": $(replicas_json),
  "host_standby": ${HOST_STANDBY:-null},
  $ENVIRONMENT_JSON
}
EOF
}

capture_environment() {
  ENVIRONMENT_JSON="\"commit\": $(json "$(git rev-parse HEAD)"),
  \"git_status\": $(json "$(git status --porcelain)"),
  \"docker_cpus\": $(docker info --format '{{.NCPU}}'),
  \"docker_memory_bytes\": $(docker info --format '{{.MemTotal}}'),
  \"docker_version\": $(json "$(docker info --format '{{.ServerVersion}}')"),
  \"settings\": $(json "$(settings)"),
  \"images\": $(json "$(image_versions)"),
  \"other_containers\": $(json "$(other_containers)")"
}

collect() {
  local service
  CAPTURED_UNTIL="$(now)"
  DLQ_AFTER="$(dlq_messages)"
  HOST_STANDBY="$(host_standby "$STARTED_AT")"
  write_conditions
  if [ "$KIND" = "carga" ]; then
    analysis capture "/app/results/$SESSION/$RUN" --start "$(date -u -d "$STARTED_AT - 60 seconds" +%Y-%m-%dT%H:%M:%SZ)" \
      --end "$CAPTURED_UNTIL" >/dev/null 2>&1 || log "a captura do Prometheus falhou"
  fi
  dc run --rm --no-deps -T web bin/rails experiment:export "DIR=/results/$SESSION/$RUN/raw/export" \
    > "$STAGE_DIR/raw/export.log" 2>&1 || log "experiment:export falhou ($STAGE_DIR/raw/export.log)"
  dc cp channel-simulator:/app/data/received.jsonl "$STAGE_DIR/raw/received.jsonl" >/dev/null 2>&1 || log "sem received.jsonl"
  mkdir -p "$STAGE_DIR/raw/logs"
  for service in web web-lb jobs-default jobs-webhooks broker-web broker-consumer agent-mock metrics channel-simulator postgres redpanda; do
    dc logs --no-color --since "$STARTED_AT" "$service" > "$STAGE_DIR/raw/logs/$service.log" 2>/dev/null || true
  done
}

analyze() {
  log "analisando $RUN"
  if analysis analyze "/app/results/$SESSION/$RUN" > "$STAGE_DIR/raw/analyze.log" 2>&1; then
    log "resumo em $STAGE_DIR/summary.json"
  else
    log "a análise falhou ($STAGE_DIR/raw/analyze.log); experiment/run.sh analisar $RUN refaz sem repetir a carga"
  fi
}

# robustness:check desde o início da carga, com o resultado em robustness.json.
robustness() {
  local output code=0 since
  since="$(date -u -d "$STARTED_AT" +%Y-%m-%dT%H:%M:%SZ)"
  output="$(dc run --rm --no-deps -T web bin/rails robustness:check "SINCE=$since" 2>/dev/null)" || code=$?
  printf '{"since": %s, "exit_code": %s, "output": %s}\n' "$(json "$since")" "$code" "$(json "$output")" > "$STAGE_DIR/robustness.json"
  log "robustness:check com código $code"
}

# Carga

k6_running() { [ "$(docker inspect -f '{{.State.Running}}' "$K6_CONTAINER" 2>/dev/null)" = "true" ]; }
stop_k6() { STOPPED_AT="$(now)"; docker kill -s INT "$K6_CONTAINER" >/dev/null; }

# run_load <etapa> <taxa> <segundos> <teto da drenagem> [parada-h1|falhas]
run_load() {
  STAGE="$1" RATE="$2" DURATION="$3"
  local drain_limit="$4" mode="${5:-}" started elapsed checked=0 code reason sampler_pid faults_pid=""
  KIND=carga STATUS=concluida REASON="" STOPPED_AT="" DRAINED=false CAPTURED_UNTIL="" K6_EXIT=null

  new_stage_dir "$STAGE"
  next_stage_number
  log "etapa $RUN: $RATE msg/s por $DURATION s"
  capture_environment
  DLQ_BEFORE="$(dlq_messages)"
  DLQ_AFTER="$DLQ_BEFORE"
  sampler "$STAGE_DIR/raw/docker-stats.csv" &
  sampler_pid=$!
  # shellcheck disable=SC2064
  trap "kill $sampler_pid 2>/dev/null || true" EXIT

  docker rm -f "$K6_CONTAINER" >/dev/null 2>&1 || true
  dc --profile experiment run -d --no-deps --name "$K6_CONTAINER" -e RATE="$RATE" -e DURATION="${DURATION}s" \
    -e SESSION="$SESSION" -e RUN="$RUN" -e STAGE_NUMBER="$STAGE_NUMBER" -e OUT_DIR="/results/$SESSION/$RUN/raw" \
    k6 run --quiet --log-format raw --console-output "/results/$SESSION/$RUN/raw/sent.jsonl" /scripts/load.js >/dev/null 2>&1
  STARTED_AT="$(docker inspect -f '{{.State.StartedAt}}' "$K6_CONTAINER" | sed -E 's/(\.[0-9]{3})[0-9]*Z/\1Z/')"
  started="$(date -u -d "$STARTED_AT" +%s)"
  write_conditions
  if [ "$mode" = "falhas" ]; then
    inject_faults "$started" &
    faults_pid=$!
  fi

  while k6_running; do
    sleep 10
    k6_running || break
    elapsed=$(( $(date +%s) - started ))
    reason="$(guard_reason)"
    if [ -n "$reason" ] && [ -z "$STOPPED_AT" ]; then
      STATUS=interrompida REASON="$reason"
      log "guarda: $reason"
      stop_k6
    elif [ "$mode" = "parada-h1" ] && [ "$checked" = "0" ] && [ "$elapsed" -ge $((H1_CHECK_SECONDS + 12)) ]; then
      checked=1
      code=0
      analysis h1-check "/app/results/$SESSION/$RUN" --rate "$RATE" --until "$H1_CHECK_SECONDS" \
        > "$STAGE_DIR/raw/h1-check.log" 2>&1 || code=$?
      log "h1-check no minuto 5: código $code; $(grep '^{' "$STAGE_DIR/raw/h1-check.log" | tail -1)"
      if [ "$code" = "3" ]; then
        STATUS=parada_h1 REASON="h1-check no minuto 5 reprovado (h1-check.json)"
        stop_k6
      fi
    fi
  done

  K6_EXIT="$(docker inspect -f '{{.State.ExitCode}}' "$K6_CONTAINER")"
  if [ "$K6_EXIT" != "0" ] && [ -z "$STOPPED_AT" ]; then
    STATUS=interrompida REASON="o k6 terminou com código $K6_EXIT"
    STOPPED_AT="$(docker inspect -f '{{.State.FinishedAt}}' "$K6_CONTAINER" | sed -E 's/(\.[0-9]{3})[0-9]*Z/\1Z/')"
  fi
  docker logs "$K6_CONTAINER" > "$STAGE_DIR/raw/k6.log" 2>&1 || true
  if [ -n "$faults_pid" ]; then
    [ "$STATUS" = "concluida" ] || kill "$faults_pid" 2>/dev/null || true
    wait "$faults_pid" 2>/dev/null || true
    write_faults
  fi

  if drain "$drain_limit"; then DRAINED=true; else log "não drenou em $drain_limit s; o restante é reportado como pendente"; fi
  # O leitor de latências do serviço metrics espera 10 s antes de ler cada entrega.
  sleep "$SETTLE_SECONDS"
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  trap - EXIT
  collect
  if [ "$mode" = "falhas" ]; then robustness; fi
  analyze
}

# Falhas da H3

sleep_until() {
  local seconds=$(( $1 - $(date +%s) ))
  if [ "$seconds" -gt 0 ]; then sleep "$seconds"; fi
}

fault() {
  local label="$1" at
  shift
  at="$(now)"
  log "falha: $label"
  "$@" >/dev/null 2>&1 || log "o comando da falha terminou com erro: $*"
  printf '{"at": %s, "label": %s, "command": %s, "finished_at": %s}\n' \
    "$(json "$at")" "$(json "$label")" "$(json "$*")" "$(json "$(now)")" >> "$STAGE_DIR/raw/faults.jsonl"
}

# Instantes contados do início do k6: minutos 2, 4, 5,5 e 7.
inject_faults() {
  local started="$1" worker=cloudesk-experiment-jobs-webhooks-1
  sleep_until $((started + 120))
  # shellcheck disable=SC2046
  fault "restart broker-web" docker restart $(dc ps -q broker-web)
  sleep_until $((started + 240))
  # shellcheck disable=SC2046
  fault "restart broker-consumer" docker restart $(dc ps -q broker-consumer)
  sleep_until $((started + 330))
  fault "kill jobs-webhooks" docker kill "$worker"
  sleep_until $((started + 420))
  fault "start jobs-webhooks" docker start "$worker"
}

write_faults() {
  { printf '{"faults": ['; paste -sd, "$STAGE_DIR/raw/faults.jsonl" 2>/dev/null || true; printf ']}\n'; } > "$STAGE_DIR/faults.json"
}

# E-mail

run_email() {
  local seed="$1" output run_id
  STAGE=email KIND=email RATE=1 DURATION=10 STATUS=concluida REASON="" STOPPED_AT="" DRAINED=false K6_EXIT=null CAPTURED_UNTIL=""
  new_stage_dir "$STAGE"
  next_stage_number
  capture_environment
  DLQ_BEFORE="$(dlq_messages)"
  dc run --rm --no-deps -T -e SIMULATOR_PERSONAS_PATH=/results/personas.json web bin/rails simulator:personas >/dev/null 2>&1 ||
    die "simulator:personas falhou"
  STARTED_AT="$(now)"
  output="$(dc exec -T channel-simulator channel-simulator send --channel email --count 10 --rate 1 --seed "$seed")"
  printf '%s\n' "$output" > "$STAGE_DIR/raw/send.json"
  run_id="$(printf '%s' "$output" | grep -o '"run_id": "[^"]*"' | sed -E 's/.*: "([^"]*)"/\1/')"
  dc cp "channel-simulator:/app/data/runs/$run_id/sent.jsonl" "$STAGE_DIR/raw/sent.jsonl" >/dev/null 2>&1 || die "sem o sent.jsonl do e-mail"
  # O e-mail passa pelo Mailpit e pelo Action Mailbox antes de virar mensagem.
  sleep 30
  if drain 180; then DRAINED=true; fi
  sleep "$SETTLE_SECONDS"
  collect
  robustness
  analyze
}

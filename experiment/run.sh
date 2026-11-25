#!/usr/bin/env bash
# Roteiro do experimento de carga. Roda da raiz do repositório (Git Bash no Windows), só no projeto
# Compose cloudesk-experiment. Cada execução grava pasta própria em experiment/results/<sessão>/.
#
#   experiment/run.sh preflight                     confere a máquina e cria a sessão
#   experiment/run.sh ensaio                        1 min a 5 msg/s, com a estrutura inteira
#   experiment/run.sh piloto [taxa] [papel=n ...]   uma rodada de 3 min (padrão 80 msg/s)
#   experiment/run.sh h3                            8 min à taxa do piloto, com as falhas
#   experiment/run.sh escada                        8 e 24 msg/s por 3 min e 80 por 5 min
#   experiment/run.sh meta                          250 msg/s por até 15 min, no ambiente da escada
#   experiment/run.sh extra                         160 ou 40 msg/s por 5 min, se 250 não foi sustentado
#   experiment/run.sh email [semente]               10 e-mails, fora da carga
#   experiment/run.sh analisar <execução>           refaz a análise de uma execução, sem carga
#   experiment/run.sh relatorio                     resumo e figuras da sessão
#   experiment/run.sh parar                         remove os contêineres do projeto
#
# SESSION=<id> escolhe outra sessão.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=experiment/lib.sh
. experiment/lib.sh

PORTS="3000 8080 8025 1025 9090 19092"
MIN_MEMORY_KB=5242880

preflight() {
  local problems=0 port key image memory containers active=0
  problem() { log "impedimento: $*"; problems=$((problems + 1)); }

  if [ -n "$(dc ps -q)" ]; then active=1; fi

  containers="$(docker ps --filter label=com.docker.compose.project=cloudesk --format '{{.Names}}')"
  if [ -n "$containers" ]; then
    problem "contêineres do projeto cloudesk em execução: $(echo "$containers" | tr '\n' ' ')"
    log "para parar: docker compose stop"
  fi

  if [ "$active" = "1" ]; then
    log "o projeto $PROJECT está de pé: portas e memória não são conferidas"
  else
    for port in $PORTS; do
      if (exec 3<> "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then problem "porta $port ocupada"; fi
    done
    memory="$(docker run --rm --entrypoint awk postgres:18 '/MemAvailable/ { print $2 }' /proc/meminfo)"
    log "MemAvailable no Docker: $((memory / 1024)) MiB"
    if [ "$memory" -lt "$MIN_MEMORY_KB" ]; then problem "menos de 5 GiB em MemAvailable"; fi
  fi

  if [ -f .env ]; then
    for key in $(grep -oE '^[A-Z_]+=' .env.example | tr -d '='); do
      grep -qE "^$key=.+" .env || problem "variável $key ausente ou vazia no .env"
    done
  else
    problem ".env ausente"
  fi

  # Os serviços Rails e o Broker rodam o código da imagem: ela é reconstruída com o código atual.
  log "construindo a imagem do Core com o código atual"
  dc build web > /dev/null 2>&1 || problem "a imagem cloudesk-core:dev não foi construída (docker compose build web)"

  for image in $(dc --profile experiment config --images | tr -d '\r' | sort -u); do
    docker image inspect "$image" >/dev/null 2>&1 || problem "imagem $image ausente (docker compose pull ou build)"
  done

  containers="$(other_containers | tr '\n' ' ')"
  log "contêineres de outros projetos: ${containers:-nenhum}"
  log "ligue o notebook na tomada, desligue a suspensão por inatividade e feche os programas pesados"

  [ "$problems" = "0" ] || die "$problems impedimento(s)"

  if [ "$active" = "1" ] && [ -f "$RESULTS/.session" ]; then
    log "aprovado; sessão $(cat "$RESULTS/.session")"
    return 0
  fi
  SESSION="$(date -u +%Y%m%dT%H%M%SZ)"
  SESSION_DIR="$RESULTS/$SESSION"
  mkdir -p "$SESSION_DIR"
  WEB=4 JOBS_WEBHOOKS=2 JOBS_DEFAULT=2 BROKER_WEB=2 BROKER_CONSUMER=2 AGENT_MOCK=1 TAXA_H3=""
  save_replicas
  echo "$SESSION" > "$RESULTS/.session"
  log "aprovado; sessão $SESSION"
}

ensaio() {
  load_session
  recreate
  warmup 10
  run_load ensaio 5 60 180
}

# As réplicas informadas (papel=n) ficam em replicas.env; a rodada sustentada define a taxa da H3.
piloto() {
  load_session
  local rate=80 pair name
  for pair in "$@"; do
    case "$pair" in
      web=* | jobs-webhooks=* | jobs-default=* | broker-web=* | broker-consumer=* | agent-mock=*)
        name="$(echo "${pair%%=*}" | tr 'a-z-' 'A-Z_')"
        printf -v "$name" '%s' "${pair#*=}"
        ;;
      [0-9]*) rate="$pair" ;;
      *) die "argumento desconhecido: $pair" ;;
    esac
  done
  save_replicas
  recreate
  warmup $((rate * 2))
  run_load piloto "$rate" 180 180
  if grep -q '"h1_sustained": true' "$STAGE_DIR/summary.json" 2>/dev/null; then
    TAXA_H3="$rate"
    save_replicas
  fi
  analysis table "/app/results/$SESSION"
}

h3() {
  load_session
  [ -n "${TAXA_H3:-}" ] || die "nenhuma taxa sustentada no piloto (TAXA_H3 vazia em replicas.env)"
  recreate
  warmup $((TAXA_H3 * 2))
  run_load h3 "$TAXA_H3" 480 300 falhas
}

escada() {
  load_session
  local rate seconds
  recreate
  warmup 500
  for rate in 8 24 80; do
    seconds=180
    [ "$rate" = "80" ] && seconds=300
    run_load "escada-$rate" "$rate" "$seconds" 180
    if [ "$DRAINED" != "true" ]; then
      recreate
      warmup 500
    fi
  done
}

meta() {
  load_session
  running web || die "o ambiente da escada não está de pé"
  run_load meta 250 900 180 parada-h1
}

extra() {
  load_session
  local rate=40
  if grep -q '"h1_sustained": true' "$SESSION_DIR"/meta-*/summary.json 2>/dev/null; then
    log "250 msg/s foi sustentado; não há degrau extra"
    return 0
  fi
  if grep -q '"h1_sustained": true' "$SESSION_DIR"/escada-80-*/summary.json 2>/dev/null; then rate=160; fi
  recreate
  warmup $((rate * 2))
  run_load extra "$rate" 300 180
}

email() {
  load_session
  running web || die "o ambiente não está de pé"
  run_email "${1:-1}"
}

analisar() {
  load_session
  RUN="$1"
  STAGE_DIR="$SESSION_DIR/$RUN"
  [ -d "$STAGE_DIR" ] || die "execução $RUN não encontrada em $SESSION_DIR"
  analyze
}

relatorio() {
  load_session
  analysis report "/app/results/$SESSION"
  analysis table "/app/results/$SESSION"
}

parar() {
  docker rm -f "$K6_CONTAINER" >/dev/null 2>&1 || true
  dc --profile experiment down --remove-orphans
}

command="${1:-}"
case "$command" in
  preflight | ensaio | piloto | h3 | escada | meta | extra | email | analisar | relatorio | parar)
    shift
    "$command" "$@"
    ;;
  *)
    sed -n '2,20p' "${BASH_SOURCE[0]}"
    exit 1
    ;;
esac

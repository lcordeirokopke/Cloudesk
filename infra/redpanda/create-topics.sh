#!/bin/sh
# Cria os tópicos do Cloudesk. Não falha quando o tópico já existe.
# Fator de replicação 1: o ambiente tem um único nó.
set -eu

BROKERS="${KAFKA_BROKERS:-redpanda:9092}"

rpk topic create agent.inbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic create agent.outbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic create agent.dlq -r 1 --if-not-exists -X brokers="$BROKERS"

rpk topic list -X brokers="$BROKERS"

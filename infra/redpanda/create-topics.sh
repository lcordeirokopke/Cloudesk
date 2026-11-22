#!/bin/sh
# Cria os tópicos do Cloudesk. Não falha quando o tópico já existe.
# Fator de replicação 1: o ambiente tem um único nó.
set -eu

BROKERS="${KAFKA_BROKERS:-redpanda:9092}"

rpk topic create agent.inbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic create agent.outbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic create agent.dlq -r 1 --if-not-exists -X brokers="$BROKERS"

# O timestamp de cada registro de agent.inbound é o horário em que o Redpanda grava a mensagem
# (LogAppendTime). O agente lê esse valor e o devolve na ação, em timestamps.kafka_appended_at.
# O alter-config vale também para o tópico que já existe.
rpk topic alter-config agent.inbound --set message.timestamp.type=LogAppendTime -X brokers="$BROKERS"

# Tópicos do kit de conformidade do agente (profile conformance do Compose): o kit publica eventos
# em conformance.inbound e lê as ações do agente sob teste em conformance.outbound, sem tocar nos
# tópicos do ambiente padrão. Mesmas partições e mesmo LogAppendTime de agent.inbound.
rpk topic create conformance.inbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic create conformance.outbound -p 6 -r 1 --if-not-exists -X brokers="$BROKERS"
rpk topic alter-config conformance.inbound --set message.timestamp.type=LogAppendTime -X brokers="$BROKERS"

rpk topic list -X brokers="$BROKERS"

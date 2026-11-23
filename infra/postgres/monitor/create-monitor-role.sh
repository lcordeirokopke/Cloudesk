#!/usr/bin/env bash
# Cria ou atualiza o papel de monitoração do Postgres, usado pelo postgres_exporter. Roda a cada subida
# do serviço postgres-monitor-init, com o superusuário, e é idempotente: cria o papel quando ele não
# existe e sempre grava a senha de DB_MONITOR_PASSWORD. O papel é membro de pg_monitor, que lê as
# estatísticas do servidor, e não recebe GRANT em tabelas de domínio. Papel de cluster, fora do
# db/structure.sql.
set -euo pipefail

: "${POSTGRES_SUPERUSER:?POSTGRES_SUPERUSER não definido}"
: "${DB_MONITOR_PASSWORD:?DB_MONITOR_PASSWORD não definido}"
MONITOR="${DB_MONITOR_USERNAME:-cloudesk_monitor}"

psql -v ON_ERROR_STOP=1 \
  --host postgres \
  --username "$POSTGRES_SUPERUSER" \
  --dbname postgres \
  -v monitor="$MONITOR" \
  -v monitor_password="$DB_MONITOR_PASSWORD" <<'SQL'
SET cloudesk.monitor TO :'monitor';
SET cloudesk.monitor_password TO :'monitor_password';
DO $$
DECLARE
  monitor text := current_setting('cloudesk.monitor');
  monitor_password text := current_setting('cloudesk.monitor_password');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = monitor) THEN
    EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB', monitor);
  END IF;
  EXECUTE format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB PASSWORD %L',
                 monitor, monitor_password);
  EXECUTE format('GRANT pg_monitor TO %I', monitor);
END
$$;
SQL

echo "papel $MONITOR pronto"

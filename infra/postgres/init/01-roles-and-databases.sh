#!/usr/bin/env bash
# Cria o papel dono, o papel da aplicação e os bancos de desenvolvimento e de teste.
# Roda uma única vez, na primeira inicialização do contêiner com o diretório de dados vazio.
set -euo pipefail

: "${DB_OWNER_USERNAME:?DB_OWNER_USERNAME não definido}"
: "${DB_OWNER_PASSWORD:?DB_OWNER_PASSWORD não definido}"
: "${DB_APP_USERNAME:?DB_APP_USERNAME não definido}"
: "${DB_APP_PASSWORD:?DB_APP_PASSWORD não definido}"
: "${DB_DEVELOPMENT_NAME:?DB_DEVELOPMENT_NAME não definido}"
: "${DB_TEST_NAME:?DB_TEST_NAME não definido}"

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname postgres \
  -v owner="$DB_OWNER_USERNAME" \
  -v owner_password="$DB_OWNER_PASSWORD" \
  -v app="$DB_APP_USERNAME" \
  -v app_password="$DB_APP_PASSWORD" \
  -v development_db="$DB_DEVELOPMENT_NAME" \
  -v test_db="$DB_TEST_NAME" <<'SQL'
CREATE ROLE :"owner" LOGIN PASSWORD :'owner_password' NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB;
CREATE ROLE :"app" LOGIN PASSWORD :'app_password' NOSUPERUSER NOBYPASSRLS NOCREATEROLE NOCREATEDB;

CREATE DATABASE :"development_db" OWNER :"owner";
CREATE DATABASE :"test_db" OWNER :"owner";
SQL

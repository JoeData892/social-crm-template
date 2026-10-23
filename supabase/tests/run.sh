#!/usr/bin/env bash
# Local test runner: SQL behavior tests + end-to-end HTTP tests of both Edge
# Functions against Postgres/pgvector and PostgREST in Docker, with a scripted
# stand-in for the Claude API (no API key or network needed).
#
# Requires: docker, psql, deno.  Usage: supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

PG_PORT=${PG_PORT:-54331}
REST_PORT=${REST_PORT:-54332}
JWT_SECRET="local-test-jwt-secret-local-test-jwt-secret"
export PGPASSWORD=test PGHOST=127.0.0.1 PGPORT=$PG_PORT PGUSER=postgres PGDATABASE=postgres

cleanup() { docker rm -f crm-test-db crm-test-rest >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

docker run -d --name crm-test-db --network host -e POSTGRES_PASSWORD=test -e PGPORT=$PG_PORT \
  pgvector/pgvector:pg17 >/dev/null
until pg_isready -q; do sleep 0.5; done
sleep 1

psql -q -v ON_ERROR_STOP=1 -f supabase/tests/bootstrap_local.sql
for m in supabase/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -f "$m"; done
psql -v ON_ERROR_STOP=1 -f supabase/tests/crm_test.sql | grep -E "PASSED|ERROR"
psql -v ON_ERROR_STOP=1 -f supabase/tests/follow_ups_test.sql | grep -E "PASSED|ERROR"

docker run -d --name crm-test-rest --network host \
  -e PGRST_DB_URI="postgres://authenticator:authenticator@127.0.0.1:$PG_PORT/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$JWT_SECRET" \
  -e PGRST_SERVER_PORT=$REST_PORT postgrest/postgrest:v12.2.8 >/dev/null
until curl -sf "http://127.0.0.1:$REST_PORT/" >/dev/null 2>&1 || curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$REST_PORT/" | grep -q 401; do sleep 0.5; done

REST_URL="http://127.0.0.1:$REST_PORT" JWT_SECRET="$JWT_SECRET" \
  deno test --allow-all supabase/tests/e2e_test.ts

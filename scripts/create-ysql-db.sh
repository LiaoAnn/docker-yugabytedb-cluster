#!/usr/bin/env bash
set -euo pipefail

# Create a YSQL database inside the yb-node-1 container (idempotent, safe identifier quoting).
#
# Usage:
#   bash scripts/create-ysql-db.sh <DB_NAME>
#
# Example:
#   bash scripts/create-ysql-db.sh appdb

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <DB_NAME>" >&2
  exit 1
fi

DB_NAME="$1"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found" >&2
  exit 1
fi

# Basic check that yb-node-1 container is running
if ! docker ps --format '{{.Names}}' | grep -q '^yb-node-1$'; then
  echo "Container yb-node-1 is not running. Start the cluster first: docker compose up -d" >&2
  exit 1
fi

# Use a DO block with format('%I') to safely quote identifier; pass target via a session GUC.
read -r -d '' YSQL_DO <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_database WHERE datname = current_setting('app.target_db', true)
  ) THEN
    EXECUTE format('CREATE DATABASE %I', current_setting('app.target_db', true));
  END IF;
END
$$;
SQL

docker compose exec -T yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte \
    --set ON_ERROR_STOP=1 \
    --set app.target_db='${DB_NAME}' \
    --command \"$YSQL_DO\""

echo "[YSQL] Database '$DB_NAME' ensured (created if missing)."

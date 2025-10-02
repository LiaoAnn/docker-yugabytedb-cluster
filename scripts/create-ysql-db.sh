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

# Query existence first (machine-friendly), then conditionally create with safe identifier quoting.
# Escape single quotes for literal comparison
ESC_DB=$(printf %s "$DB_NAME" | sed "s/'/''/g")
EXISTS=$(docker compose exec -T yb-node-1 bash -lc \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte \
    -At --set ON_ERROR_STOP=1 \
    --command \"SELECT 1 FROM pg_database WHERE datname = '$ESC_DB';\"" | tr -d '\r')

if [[ -z "$EXISTS" ]]; then
  SAFE_DB=${DB_NAME//\"/\"\"}
  docker compose exec -T yb-node-1 bash -lc \
    "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte \
      --set ON_ERROR_STOP=1 \
      --command \"CREATE DATABASE \"\"$SAFE_DB\"\";\""
fi

echo "[YSQL] Database '$DB_NAME' ensured (created if missing)."

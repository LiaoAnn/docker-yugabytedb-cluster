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

# Detect docker compose command variant and whether -T is supported.
# Prefer: docker compose (v2) -> docker-compose (v1), otherwise fallback to docker exec without -T.
COMPOSE_CMD=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
fi

TTY_FLAG=""
if ((${#COMPOSE_CMD[@]} > 0)); then
  if "${COMPOSE_CMD[@]}" exec --help 2>&1 | grep -q ' -T'; then
    TTY_FLAG="-T"
  fi
fi

# Helper to run a command inside the service/container in a cross-environment way.
run_in_service() {
  local service="$1"; shift
  local cmd="$*"
  if ((${#COMPOSE_CMD[@]} > 0)); then
    "${COMPOSE_CMD[@]}" exec ${TTY_FLAG:+$TTY_FLAG} "$service" bash -lc "$cmd"
  else
    # Fallback to docker exec (no -T flag exists for docker exec; omitting -t yields non-TTY)
    docker exec "$service" bash -lc "$cmd"
  fi
}

# Basic check that yb-node-1 container is running
if ! docker ps --format '{{.Names}}' | grep -q '^yb-node-1$'; then
  echo "Container yb-node-1 is not running. Start the cluster first: 'docker compose up -d' or 'docker-compose up -d'" >&2
  exit 1
fi

# Query existence first (machine-friendly), then conditionally create with safe identifier quoting.
# Escape single quotes for literal comparison
ESC_DB=$(printf %s "$DB_NAME" | sed "s/'/''/g")
EXISTS=$(run_in_service yb-node-1 \
  "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte \
    -At --set ON_ERROR_STOP=1 \
    --command \"SELECT 1 FROM pg_database WHERE datname = '$ESC_DB';\"" | tr -d '\r')

if [[ -z "$EXISTS" ]]; then
  SAFE_DB=${DB_NAME//\"/\"\"}
  run_in_service yb-node-1 \
    "/home/yugabyte/bin/ysqlsh --host \$(hostname) --username yugabyte --dbname yugabyte \
      --set ON_ERROR_STOP=1 \
      --command \"CREATE DATABASE \"\"$SAFE_DB\"\";\""
fi

echo "[YSQL] Database '$DB_NAME' ensured (created if missing)."

#!/usr/bin/env bash
set -euo pipefail

# Create a YCQL keyspace inside the yb-node-1 container (idempotent), default RF=3.
#
# Usage:
#   bash scripts/create-ycql-keyspace.sh <KEYSPACE_NAME> [RF]
#
# Example:
#   bash scripts/create-ycql-keyspace.sh appks 3

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <KEYSPACE_NAME> [RF]" >&2
  exit 1
fi

KS_NAME="$1"
RF="${2:-3}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found" >&2
  exit 1
fi

if ! [[ "$RF" =~ ^[0-9]+$ ]] || [[ "$RF" -lt 1 ]]; then
  echo "Invalid replication factor: $RF (must be a positive integer)" >&2
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

# SimpleStrategy suitable for single-DC local development.
CQL="CREATE KEYSPACE IF NOT EXISTS \"$KS_NAME\" WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': $RF };"

run_in_service yb-node-1 \
  "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"$CQL\""

echo "[YCQL] Keyspace '$KS_NAME' ensured with RF=$RF (created if missing)."

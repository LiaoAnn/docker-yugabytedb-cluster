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

# Basic check that yb-node-1 container is running
if ! docker ps --format '{{.Names}}' | grep -q '^yb-node-1$'; then
  echo "Container yb-node-1 is not running. Start the cluster first: docker compose up -d" >&2
  exit 1
fi

# SimpleStrategy suitable for single-DC local development.
CQL="CREATE KEYSPACE IF NOT EXISTS \"$KS_NAME\" WITH REPLICATION = { 'class': 'SimpleStrategy', 'replication_factor': $RF };"

docker compose exec -T yb-node-1 bash -lc \
  "/home/yugabyte/bin/ycqlsh \$(hostname) 9042 -e \"$CQL\""

echo "[YCQL] Keyspace '$KS_NAME' ensured with RF=$RF (created if missing)."

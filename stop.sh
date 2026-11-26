#!/usr/bin/env bash
# Stop OpenRelik, its workers, Elasticsearch and Kibana. Data is kept.
# Usage: ./stop.sh [openrelik dir]   (default: ./openrelik)
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENRELIK_DIR="${1:-$PWD/openrelik}"

docker compose -f "$STACK_DIR/elk/docker-compose.yml" stop
if [[ -f "$OPENRELIK_DIR/docker-compose.yml" ]]; then
  (cd "$OPENRELIK_DIR" && docker compose stop)
fi
echo "Stopped. Start again with ./setup.sh"

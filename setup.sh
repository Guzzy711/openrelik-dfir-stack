#!/usr/bin/env bash
# Set up OpenRelik with the UAC, iLEAPP, ALEAPP and Elasticsearch workers, and a local
# Elasticsearch + Kibana. Safe to run again: each step skips what is already done.
#
# Usage: ./setup.sh [openrelik dir]   (default: ./openrelik, made by the installer)
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENRELIK_DIR="${1:-$PWD/openrelik}"
INSTALLER_URL="https://raw.githubusercontent.com/openrelik/openrelik/main/deploy/docker/install.sh"
ES="http://localhost:9200"
KIBANA="http://localhost:5601"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m%s\033[0m\n' "$*" >&2; exit 1; }

wait_for() {  # wait_for <name> <url>
  printf 'Waiting for %s' "$1"
  for _ in $(seq 1 120); do
    if curl -fs "$2" >/dev/null 2>&1; then echo " ready"; return; fi
    printf '.'; sleep 5
  done
  fail " $1 did not start; see: docker compose -f $STACK_DIR/elk/docker-compose.yml logs"
}

step "Checking Docker"
command -v docker >/dev/null || fail "Docker is not installed: https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || fail "The Docker Compose plugin is missing."
command -v curl >/dev/null || fail "curl is not installed."

step "OpenRelik"
if [[ -f "$OPENRELIK_DIR/docker-compose.yml" ]]; then
  echo "Found $OPENRELIK_DIR"
else
  echo "Not installed: running the official installer in $(dirname "$OPENRELIK_DIR")."
  echo "Write down the admin password it prints at the end."
  (cd "$(dirname "$OPENRELIK_DIR")" && curl -fsSL "$INSTALLER_URL" -o install.sh && bash install.sh)
  [[ -f "$OPENRELIK_DIR/docker-compose.yml" ]] || fail "The installer did not create $OPENRELIK_DIR"
fi

step "Workers (UAC, iLEAPP, ALEAPP, Elasticsearch)"
override="$OPENRELIK_DIR/docker-compose.override.yml"
if [[ -f "$override" ]] && ! cmp -s "$override" "$STACK_DIR/docker-compose.override.yml"; then
  cp "$override" "$override.bak.$(date +%Y%m%d%H%M%S)"
  echo "Saved the existing override as $override.bak.*"
fi
cp "$STACK_DIR/docker-compose.override.yml" "$override"
(cd "$OPENRELIK_DIR" \
  && docker compose pull openrelik-worker-uac openrelik-worker-ileapp \
     openrelik-worker-aleapp openrelik-worker-elasticsearch \
  && docker compose up -d)

step "Elasticsearch and Kibana"
docker compose -f "$STACK_DIR/elk/docker-compose.yml" up -d
wait_for Elasticsearch "$ES/_cluster/health"

# One node: no replicas, or every index stays yellow.
for pattern in uac openrelik ileapp aleapp; do
  curl -fs -X PUT "$ES/_index_template/$pattern" -H 'Content-Type: application/json' \
    -d "{\"index_patterns\": [\"$pattern-*\"], \"template\": {\"settings\": {\"number_of_replicas\": 0}}}" \
    >/dev/null
done
echo "Index templates: uac-*, openrelik-*, ileapp-*, aleapp-* (no replicas)"

wait_for Kibana "$KIBANA/api/status"
data_view() {  # data_view <id> <pattern> <name>
  curl -fs -X POST "$KIBANA/api/data_views/data_view" -H 'kbn-xsrf: true' \
    -H 'Content-Type: application/json' \
    -d "{\"override\": true, \"data_view\": {\"id\": \"$1\", \"title\": \"$2\", \"name\": \"$3\", \"timeFieldName\": \"@timestamp\"}}" \
    >/dev/null
}
data_view uac "uac-*" "UAC timelines"
data_view ileapp "ileapp-*" "iLEAPP timelines"
data_view aleapp "aleapp-*" "ALEAPP timelines"
data_view openrelik "openrelik-*" "OpenRelik exports"
curl -fs -X POST "$KIBANA/api/data_views/default" -H 'kbn-xsrf: true' \
  -H 'Content-Type: application/json' -d '{"data_view_id": "uac", "force": true}' >/dev/null
echo "Kibana data views: UAC, iLEAPP and ALEAPP timelines, OpenRelik exports"

step "Done"
cat <<EOF
OpenRelik:      http://localhost:8711   (user admin, password from the installer)
Kibana:         $KIBANA
Elasticsearch:  $ES

In an OpenRelik workflow, export timelines with "Elasticsearch Export": index name
uac-<host>, ileapp-<device>, aleapp-<device> or openrelik-<anything>, "Parse input as JSON lines" on.
EOF

#!/usr/bin/env bash
# Configure Elasticsearch and Kibana for the stack's timelines. Safe to run again.
#
# - Index templates for uac-*, ileapp-*, aleapp-*, macapt-*, dissect-*, hayabusa-* and openrelik-*:
#   no replicas (one node), ECS field types, room for many fields, and the super-timeline
#   ingest pipeline.
# - The super-timeline pipeline (super-timeline/): fills host.name, event.category,
#   event.action, event.kind, event.dataset, artifact.name/description and the ECS
#   fields the tools have (user, IPs, process, URL, hashes, rule) the same way for every tool.
# - Existing indexes get the same, in the background (update by query). An index where a
#   field the pipeline makes an ECS object (artifact, url, user, source, ...) is plain text
#   is copied into a new index through the pipeline; the old one is deleted once the copy has every document, and its
#   name becomes an alias of the new one, so exports to it keep working.
# - Kibana: a data view per tool, the "Super timeline" data view over all of them, and a
#   "Super timeline" Discover search with fixed columns.
#
# Usage: elk/configure.sh   (ES and KIBANA override http://localhost:9200 and :5601)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)/super-timeline"
ES="${ES:-http://localhost:9200}"
KIBANA="${KIBANA:-http://localhost:5601}"
PATTERNS=(uac ileapp aleapp macapt dissect hayabusa openrelik)
VERSION="$(sed -n 's/^ *"version": *\([0-9][0-9]*\).*/\1/p' "$DIR/rules.json" | head -1)"

es() {  # es <method> <path> [body]: the body is read from stdin when it is "-"
  if [[ $# -gt 2 ]]; then
    curl -fsS -X "$1" "$ES$2" -H 'Content-Type: application/json' --data-binary "$3"
  else
    curl -fsS -X "$1" "$ES$2"
  fi
}
kibana() {  # kibana <method> <path> <body>
  curl -fsS -X "$1" "$KIBANA$2" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    --data-binary "$3" >/dev/null
}
# A file as the contents of a JSON string.
json_string() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$1" | awk '{printf "%s\\n", $0}'; }

# The pipeline: pipeline.painless with rules.json and descriptions.json as its params.
es PUT /_ingest/pipeline/super-timeline @- >/dev/null <<JSON
{
  "description": "Super timeline: the same ECS fields for every tool (version $VERSION)",
  "processors": [{
    "script": {
      "tag": "super-timeline",
      "lang": "painless",
      "source": "$(json_string "$DIR/pipeline.painless")",
      "params": {"rules": $(cat "$DIR/rules.json"), "descriptions": $(cat "$DIR/descriptions.json")},
      "on_failure": [
        {"append": {"field": "tags", "value": "super_timeline_error"}},
        {"set": {"field": "error.message", "value": "{{ _ingest.on_failure_message }}"}}
      ]
    }
  }]
}
JSON
echo "Ingest pipeline: super-timeline (rules version $VERSION)"

# Dissect and Plaso timelines have hundreds of field names: allow more, and skip the
# fields past the limit instead of refusing the document. The ECS fields are always mapped.
FIELD_LIMITS='"index.mapping.total_fields.limit": 5000, "index.mapping.total_fields.ignore_dynamic_beyond_limit": true'
SETTINGS="{\"number_of_replicas\": 0, \"index.default_pipeline\": \"super-timeline\", $FIELD_LIMITS}"

es PUT /_component_template/super-timeline @- >/dev/null <<JSON
{"template": {"mappings": $(cat "$DIR/mappings.json")}}
JSON
for pattern in "${PATTERNS[@]}"; do
  es PUT "/_index_template/$pattern" @- >/dev/null <<JSON
{
  "index_patterns": ["$pattern-*"],
  "composed_of": ["super-timeline"],
  "template": {"settings": $SETTINGS}
}
JSON
done
echo "Index templates: ${PATTERNS[*]/%/-*} (no replicas, ECS fields, super-timeline pipeline)"

# Existing indexes: the same field types and pipeline, and their documents updated in the
# background unless the pipeline already ran on them with these rules.
indexes() { es GET "/_cat/indices/$(IFS=,; echo "${PATTERNS[*]/%/-*}")?h=index&expand_wildcards=open" | sort; }

wait_task() {  # wait_task <task id>: until it completes; prints its response
  local status
  while :; do
    status="$(es GET "/_tasks/$1")"
    if [[ "$status" == *'"completed":true'* ]]; then echo "$status"; return; fi
    sleep 5
  done
}

# Fields the pipeline makes ECS objects of (artifact; Dissect's url, user, source, server)
# can't change type in an index that has them as plain text: copy such an index through
# the pipeline.
OBJECTS="artifact,$(sed -n '/"ecs_objects"/,/\]/p' "$DIR/rules.json" | tr -d ' \n' | sed 's/.*\[//; s/\].*//; s/"//g')"
for index in $(indexes); do
  mapping="$(es GET "/$index/_mapping/field/$OBJECTS")"
  [[ "$mapping" == *'"full_name"'* ]] || continue
  target="$index-st$VERSION"
  echo "  $index: has text fields that are ECS objects now; copying it to $target through the pipeline"
  es PUT "/$target" '{}' >/dev/null
  task="$(es POST "/_reindex?wait_for_completion=false" \
    "{\"source\": {\"index\": \"$index\"}, \"dest\": {\"index\": \"$target\", \"pipeline\": \"super-timeline\"}}" \
    | sed -n 's/.*"task" *: *"\([^"]*\)".*/\1/p')"
  result="$(wait_task "$task")"
  es POST "/$target/_refresh" >/dev/null
  old="$(es GET "/$index/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  new="$(es GET "/$target/_count" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')"
  if [[ -n "$old" && "$old" == "$new" && "$result" != *'"failures":[{'* ]]; then
    es DELETE "/$index" >/dev/null
    es POST /_aliases "{\"actions\": [{\"add\": {\"index\": \"$target\", \"alias\": \"$index\", \"is_write_index\": true}}]}" >/dev/null
    echo "  $index: now an alias of $target ($new documents)"
  else
    echo "  $index: copy has $new of $old documents; kept both, $target needs a look" >&2
  fi
done

for index in $(indexes); do
  es PUT "/$index/_settings" "{\"index.default_pipeline\": \"super-timeline\", $FIELD_LIMITS}" >/dev/null
  if ! es PUT "/$index/_mapping" "$(cat "$DIR/mappings.json")" >/dev/null 2>&1; then
    echo "  $index: has other types for the ECS fields; its Super timeline columns may be empty" >&2
  fi
  task="$(es POST "/$index/_update_by_query?pipeline=super-timeline&conflicts=proceed&wait_for_completion=false" \
    "{\"query\": {\"bool\": {\"must_not\": {\"range\": {\"super_timeline_version\": {\"gte\": $VERSION}}}}}}" \
    | sed -n 's/.*"task" *: *"\([^"]*\)".*/\1/p')"
  echo "  $index: updating in the background (task $task)"
done

# Kibana
data_view() {  # data_view <id> <pattern> <name>
  kibana POST /api/data_views/data_view \
    "{\"override\": true, \"data_view\": {\"id\": \"$1\", \"title\": \"$2\", \"name\": \"$3\", \"timeFieldName\": \"@timestamp\"}}"
}
data_view uac "uac-*" "UAC timelines"
data_view ileapp "ileapp-*" "iLEAPP timelines"
data_view aleapp "aleapp-*" "ALEAPP timelines"
data_view macapt "macapt-*" "mac_apt timelines"
data_view dissect "dissect-*" "Dissect timelines"
data_view hayabusa "hayabusa-*" "Hayabusa detections"
data_view openrelik "openrelik-*" "OpenRelik exports"
data_view super-timeline "$(IFS=,; echo "${PATTERNS[*]/%/-*}")" "Super timeline"
kibana POST /api/data_views/default '{"data_view_id": "super-timeline", "force": true}'

# Times as ISO 8601 in UTC (2015-03-25T10:15:38.914+00:00), not the browser's time zone;
# dark mode; a new Discover search starts with the Super timeline's columns and the last
# 5 years (evidence is older than Kibana's default 15 minutes).
kibana POST /api/kibana/settings \
  '{"changes": {"dateFormat": "YYYY-MM-DD[T]HH:mm:ss.SSSZ", "dateFormat:tz": "UTC", "dateFormat:dow": "Monday", "theme:darkMode": true, "defaultColumns": ["host.name", "event.category", "event.action", "message"], "timepicker:timeDefaults": "{\"from\": \"now-5y\", \"to\": \"now\"}"}}'

# A data view can't fix the columns; a saved Discover search can.
kibana POST "/api/saved_objects/search/super-timeline?overwrite=true" @- <<'JSON'
{
  "attributes": {
    "title": "Super timeline",
    "description": "Every timeline with the same columns: host, ECS category, action, message.",
    "columns": ["host.name", "event.category", "event.action", "message"],
    "sort": [["@timestamp", "desc"]],
    "kibanaSavedObjectMeta": {
      "searchSourceJSON": "{\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[],\"indexRefName\":\"kibanaSavedObjectMeta.searchSourceJSON.index\"}"
    }
  },
  "references": [
    {"name": "kibanaSavedObjectMeta.searchSourceJSON.index", "type": "index-pattern", "id": "super-timeline"}
  ]
}
JSON
echo "Kibana: data views per tool and \"Super timeline\" (default), Discover search \"Super timeline\", ISO 8601 times in UTC, dark mode"

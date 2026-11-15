#!/bin/sh -eu
# Sync destinations, streams, dashboards, and alerts into OpenObserve via its
# REST API (OSS has no CRDs/CLI for these — cmdshift/platform#171).
# Create-only dashboards: POST always creates, so existence-check by title
# first; Git edits after first creation do not propagate (UI edits win).

O2_URL="${O2_URL:-http://openobserve.observability.svc:5080}"
ORG="${ORG:-default}"
AUTH="$O2_USER:$O2_PASS"
MAX_STREAM_RETRIES="${MAX_STREAM_RETRIES:-10}"

log() { echo "openobserve-sync: $*" >&2; }
log "target=$O2_URL org=$ORG user=${O2_USER:-unset}"

# req METHOD PATH [BODY_FILE] -> writes response BODY to stdout, and logs
# everything (status + body) to stderr; sets $REQ_STATUS
# PATH is appended under /api/$ORG/ — EXCEPT when it starts with "//", which
# nests at /api/ directly (the v2 alerts API lives at /api/v2/{org}/alerts:
# v2 before org, so org-first spelling 404s, cmdshift/platform#171)
REQ_STATUS=0
req() {
  method=$1; path=$2; body=${3:-}
  case "$path" in
    //*) url="$O2_URL/api${path#/}" ;;
    *)   url="$O2_URL/api/$ORG/$path" ;;
  esac
  tmp_body=$(mktemp)
  tmp_hdr=$(mktemp)
  if [ -n "$body" ]; then
    curl -s -D "$tmp_hdr" -o "$tmp_body" -u "$AUTH" -X "$method" \
      -H 'Content-Type: application/json' -d @"$body" "$url" || true
  else
    curl -s -D "$tmp_hdr" -o "$tmp_body" -u "$AUTH" -X "$method" "$url" || true
  fi
  REQ_STATUS=$(head -n1 "$tmp_hdr" | awk '{print $2}')
  log "REQ $method $path -> status=${REQ_STATUS:-none}"
  if [ "${REQ_STATUS:-none}" = "none" ] || [ "$REQ_STATUS" -ge 400 ] 2>/dev/null; then
    log "REQ $url failed, response body:"
    log "$(cat "$tmp_body" | head -c 500)"
  fi
  cat "$tmp_body"
  rm -f "$tmp_body" "$tmp_hdr"
}

req_ok() {
  req "$@"
  [ "$REQ_STATUS" -ge 200 ] && [ "$REQ_STATUS" -lt 300 ] 2>/dev/null
}

# ---------- destinations first (alerts reference them) ----------
sync_destinations() {
  log "destinations dir contents: $(ls /destinations 2>&1)"
  for f in /destinations/*.json; do
    [ -f "$f" ] || { log "missing $f"; exit 1; }
    log "destination file head: $(head -c 120 "$f")"
    name=$(jq -r '.name' "$f") || { log "jq failed on $f"; exit 1; }
    existing=$(req_ok GET "alerts/destinations" | jq -r --arg n "$name" \
      '[.. | objects | select(.name? == $n) | .name] | first // empty' || true)
    if [ -n "$existing" ]; then
      log "destination exists: $name"
    else
      req_ok POST "alerts/destinations" "$f" >/dev/null && log "destination created: $name"
    fi
  done
}

stream_exists() {
  stream_name=$1; stream_type=$2
  streams_list=$(req_ok GET "streams?type=$stream_type" || echo '{}')
  echo "$streams_list" | jq -r --arg s "$stream_name" \
    '[.. | objects | select(.name? == $s) | .name] | first // empty' || true
}

seed_metrics_stream() {
  stream_name=$1
  seed_value=0
  [ "${2:-0}" = "now" ] && seed_value=$(date +%s)
  seed_file=$(mktemp)
  echo "[{\"__name__\": \"$stream_name\", \"__type__\": \"gauge\", \"value\": $seed_value, \"_timestamp\": $(date +%s)000000}]" > "$seed_file"
  req_ok POST "ingest/metrics/_json" "$seed_file" >/dev/null && log "stream seeded: $stream_name (metrics)"
  rm -f "$seed_file"
}

seed_logs_stream() {
  stream_name=$1
  seed_file=$(mktemp)
  echo "[{\"_timestamp\": $(date +%s)000000, \"message\": \"seed\"}]" > "$seed_file"
  req_ok POST "$stream_name/_json" "$seed_file" >/dev/null && log "stream seeded: $stream_name (logs)"
  rm -f "$seed_file"
}

# /streams holds per-dashboard manifests, each a JSON array of
# {"stream": "<name>", "type": "metrics"|"logs"} — seed only missing streams,
# so dashboards render instead of showing empty until real data arrives.
# "seed": "now" seeds the CURRENT epoch instead of 0 — required for
# timestamp-style gauges (velero_backup_last_successful_timestamp): a 0 value
# reads as "last success at epoch 0" and would fire the staleness alert.
seed_streams() {
  for f in /streams/*.json; do
    [ -f "$f" ] || return 0
    entries=$(jq 'length' "$f")
    i=0
    while [ "$i" -lt "$entries" ]; do
      entry=$(jq -c ".[$i]" "$f")
      stream_name=$(echo "$entry" | jq -r '.stream')
      stream_type=$(echo "$entry" | jq -r '.type')
      seed=$(echo "$entry" | jq -r '.seed // "0"')
      [ -n "$stream_name" ] && [ "$stream_name" != "null" ] || { log "no stream in $f"; exit 1; }
      # the `up` stream must never be touched here (no fake up=1 rows)
      if [ "$stream_name" = "up" ]; then
        log "refusing to seed protected stream: up"
        i=$((i + 1))
        continue
      fi
      if [ -n "$(stream_exists "$stream_name" "$stream_type")" ]; then
        log "stream exists: $stream_name"
      else
        case $stream_type in
          metrics) seed_metrics_stream "$stream_name" "$seed" ;;
          logs) seed_logs_stream "$stream_name" ;;
          *) log "unknown stream_type for $f: $stream_type"; exit 1 ;;
        esac
      fi
      i=$((i + 1))
    done
  done
}

dashboard_id_for_title() {
  title=$1
  existing_dashboards=$(req_ok GET "dashboards" || echo '{}')
  # v1.0 list shape: each entry carries dashboard_id (snake, entry level) and a
  # version-nested body (v5.dashboardId, camel) — walk every object with a
  # matching title and take whichever id field exists
  echo "$existing_dashboards" | jq -r --arg t "$title" \
    '[.. | objects | select(.title? == $t) | (.dashboardId // .dashboard_id // empty)] | first // empty'
}

create_dashboard() {
  f=$1
  req_ok POST "dashboards" "$f" >/dev/null
  log "dashboard created: $(jq -r '.title' "$f")"
}

# dashboards: POST always creates, so look up by title per file — re-fetch the
# list each iteration: concurrent sync runs (Job retries) race the snapshot
# and create duplicates otherwise.
sync_dashboards() {
  for f in $(find /dashboards -name '*.json' | sort); do
    title=$(jq -r '.title' "$f")
    dash_id=$(dashboard_id_for_title "$title")
    if [ -n "$dash_id" ]; then
      log "dashboard exists: $title ($dash_id)"
    else
      create_dashboard "$f"
    fi
  done
}

# alerts: stream must exist (StreamNotFound) → bounded retry.
# v2 API: /api/v2/{org}/alerts — v2 nests BEFORE the org segment in the router,
# so these calls use the "//"-prefixed path (cmdshift/platform#171).
sync_alerts() {
  for f in /alerts/*.json; do
    [ -f "$f" ] || return 0
    name=$(jq -r '.name' "$f")
    existing_alerts=$(req_ok GET "//v2/$ORG/alerts" 2>/dev/null || echo '[]')
    existing=$(echo "$existing_alerts" | jq -r --arg n "$name" \
      '[.. | objects | select(.name? == $n) | .name] | first // empty' || true)
    if [ -n "$existing" ]; then
      log "alert exists: $name"
      continue
    fi
    attempt=1
    while :; do
      if req_ok POST "//v2/$ORG/alerts" "$f" >/dev/null; then
        log "alert created: $name"
        break
      fi
      if [ "$attempt" -ge "$MAX_STREAM_RETRIES" ]; then
        log "alert FAILED (stream never appeared after $attempt attempts): $name"
        exit 1
      fi
      log "stream not ready for $name — retry $attempt/$MAX_STREAM_RETRIES"
      attempt=$((attempt + 1))
      sleep 30
    done
  done
}

main() {
  sync_destinations
  seed_streams
  sync_dashboards
  sync_alerts
  log "sync complete"
}

main "$@"

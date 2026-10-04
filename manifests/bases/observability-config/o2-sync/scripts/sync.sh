#!/bin/sh -eu
# Sync dashboards, alert destinations, and alerts into OpenObserve via its
# REST API (OSS has no CRDs/CLI for these — cmdshift/platform#171).
# Hash-triggered: the Job's pod template references hash-suffixed ConfigMaps,
# so any content change recreates the Job (kustomize.toolkit.fluxcd.io/force).

O2_URL="${O2_URL:-http://openobserve.observability.svc:5080}"
ORG="${ORG:-default}"
AUTH="${O2_USER}:${O2_PASS}"
MAX_STREAM_RETRIES="${MAX_STREAM_RETRIES:-10}"

log() { echo "o2-sync: $*" >&2; }
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
# /destinations holds template + destination JSONs (CM-mounted, one flat dir);
# template must exist before the destination references it
log "destinations dir contents: $(ls /destinations 2>&1)"
for f in /destinations/alertmanager-template.json /destinations/alertmanager.json; do
  [ -f "$f" ] || { log "missing $f"; exit 1; }
  log "destination file head: $(head -c 120 "$f")"
  name=$(jq -r '.name' "$f") || { log "jq failed on $f"; exit 1; }
  if echo "$f" | grep -q template; then
    existing=$(req_ok GET "alerts/templates" | jq -r --arg n "$name" \
      '[.. | objects | select(.name? == $n) | .name] | first // empty' || true)
    if [ -n "$existing" ]; then
      log "template exists: $name"
    else
      req_ok POST "alerts/templates" "$f" >/dev/null && log "template created: $name"
    fi
  else
    existing=$(req_ok GET "alerts/destinations" | jq -r --arg n "$name" \
      '[.. | objects | select(.name? == $n) | .name] | first // empty' || true)
    if [ -n "$existing" ]; then
      log "destination exists: $name"
    else
      req_ok POST "alerts/destinations" "$f" >/dev/null && log "destination created: $name"
    fi
  fi
done

# ---------- dashboards: POST always creates, PUT needs ?hash= ----------
# /dashboards may hold several domain CMs mounted as subdirs — walk them all.
# Re-fetch the list per file: concurrent sync runs (Job retries) race the
# snapshot and create duplicates otherwise.
find /dashboards -name '*.json' | sort | while read -r f; do
  title=$(jq -r '.title' "$f")
  existing_dashboards=$(req_ok GET "dashboards" || echo '{}')
  dash_id=$(echo "$existing_dashboards" | jq -r --arg t "$title" \
    'if type == "object" then ([.dashboards[]? | select(.title == $t)][0].dashboardId // empty) else empty end')
  if [ -n "$dash_id" ]; then
    hash=$(req_ok GET "dashboards/$dash_id" | jq -r '.hash')
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
      -H 'Content-Type: application/json' -d @"$f" \
      "$O2_URL/api/$ORG/dashboards/$dash_id?hash=$hash")
    case $code in
      200) log "dashboard updated: $title" ;;
      409) log "dashboard conflict (hash mismatch), skipped: $title" ;;
      *) log "dashboard FAILED ($code): $title"; exit 1 ;;
    esac
  else
    req_ok POST "dashboards" "$f" >/dev/null && log "dashboard created: $title"
  fi
done

# ---------- alerts: stream must exist (StreamNotFound) → bounded retry ----------
# v2 API: /api/v2/{org}/alerts — v2 nests BEFORE the org segment in the router
# (/api/{org}/v2/alerts 404s), so these calls bypass req()'s org-first spelling
# and pass the full path (cmdshift/platform#171). Re-fetch per file:
# concurrent sync runs race the snapshot and create duplicates otherwise.
alerts_url_base="//v2"
for f in /alerts/*.json; do
  [ -f "$f" ] || continue
  name=$(jq -r '.name' "$f")
  existing_alerts=$(req_ok GET "$alerts_url_base/$ORG/alerts" 2>/dev/null || echo '[]')
  # v2 list returns {"list":[…]} — walk either shape without indexing non-objects
  existing=$(echo "$existing_alerts" | jq -r --arg n "$name" \
    '[.. | objects | select(.name? == $n) | .name] | first // empty' || true)
  if [ -n "$existing" ]; then
    log "alert exists: $name"
    continue
  fi
  attempt=1
  while :; do
    if req_ok POST "$alerts_url_base/$ORG/alerts" "$f" >/dev/null; then
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

log "sync complete"

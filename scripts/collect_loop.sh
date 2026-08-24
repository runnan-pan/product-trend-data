#!/bin/bash
# Continuous collect loop for one retailer backend repo.
#
# Repeats forever: refresh the sitemap catalog, then live-collect it. A
# "round" is one make sitemap + make collect pass (make collect already
# retries same-day failures internally before it returns). When a round
# ends:
#   - blocked (403/429/503, or the sitemap fetch itself failed): back off
#     BLOCK_BACKOFF_SECONDS before trying again.
#   - nothing was pending (everything for today was already collected):
#     sleep until the next Australia/Sydney calendar day, since the backend
#     dedupes to one snapshot per day and looping sooner would just refetch
#     the sitemap for no new data.
#   - otherwise (made real progress): start the next round immediately.
#
# Usage: collect_loop.sh <path-to-backend-repo>
# Run manually to test: bash scripts/collect_loop.sh "../Chemist Warehouse Trend"
# Scheduled via launchd — one agent per retailer so they run concurrently,
# see com.pricetrend.collect-chemist.plist / com.pricetrend.collect-bunnings.plist

set -uo pipefail

PROJECT_DIR="${1:-}"
if [ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ]; then
  echo "usage: collect_loop.sh <path-to-backend-repo>" >&2
  exit 1
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
SLUG="$(echo "$PROJECT_NAME" | tr '[:upper:] ' '[:lower:]-')"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_DIR="/tmp/price-trend-collect-${SLUG}.lock"
LOG_FILE="$SCRIPT_DIR/collect-${SLUG}.log"
LAST_COLLECT="$PROJECT_DIR/backend/data/last-collect.json"

BLOCK_BACKOFF_SECONDS=3600

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$PROJECT_NAME] $1" >>"$LOG_FILE"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "skip: another instance is already running (found $LOCK_DIR)"
  exit 0
fi
cleanup() { rmdir "$LOCK_DIR" 2>/dev/null; }
trap cleanup EXIT

# A full pass can take hours. Keep the Mac from idle-sleeping for as long as
# this loop's own process is alive; caffeinate exits with it.
caffeinate -i -w $$ &

cd "$PROJECT_DIR"

seconds_until_next_sydney_midnight() {
  python3 - <<'PY'
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

tz = ZoneInfo("Australia/Sydney")
now = datetime.now(tz)
tomorrow = (now + timedelta(days=1)).date()
midnight = datetime(tomorrow.year, tomorrow.month, tomorrow.day, tzinfo=tz)
print(max(60, int((midnight - now).total_seconds())))
PY
}

last_collect_field() {
  python3 -c "
import json
try:
    data = json.load(open('$LAST_COLLECT'))
except (OSError, ValueError):
    data = {}
value = data.get('$1')
print('' if value is None else value)
"
}

log "=== collect loop started (pid $$) ==="

while true; do
  log "round start: make sitemap"
  if ! make sitemap >>"$LOG_FILE" 2>&1; then
    log "sitemap fetch failed or was blocked, sleeping ${BLOCK_BACKOFF_SECONDS}s"
    sleep "$BLOCK_BACKOFF_SECONDS"
    continue
  fi

  log "round: make collect"
  if ! make collect >>"$LOG_FILE" 2>&1; then
    log "collect crashed, sleeping ${BLOCK_BACKOFF_SECONDS}s"
    sleep "$BLOCK_BACKOFF_SECONDS"
    continue
  fi

  if [ ! -f "$LAST_COLLECT" ]; then
    log "no last-collect.json written, sleeping ${BLOCK_BACKOFF_SECONDS}s"
    sleep "$BLOCK_BACKOFF_SECONDS"
    continue
  fi

  HALTED_REASON="$(last_collect_field halted_reason)"
  PENDING="$(last_collect_field pending)"

  if [ -n "$HALTED_REASON" ]; then
    log "round halted ($HALTED_REASON): sleeping ${BLOCK_BACKOFF_SECONDS}s before retry"
    sleep "$BLOCK_BACKOFF_SECONDS"
  elif [ "$PENDING" = "0" ]; then
    WAIT="$(seconds_until_next_sydney_midnight)"
    log "nothing pending today: sleeping ${WAIT}s until next Sydney day"
    sleep "$WAIT"
  else
    log "round made progress (pending was $PENDING): starting next round immediately"
  fi
done

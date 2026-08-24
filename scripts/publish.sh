#!/bin/bash
# Daily job: export static history JSON for every retailer backend and
# publish the result as one commit to product-trend-data.
#
# This is separate from collecting (see collect_loop.sh, which runs
# continuously). This script only turns whatever is already recorded in each
# backend's prices.db into JSON and pushes it — it never touches a retailer
# site.
#
# Run manually to test: bash scripts/publish.sh
# Scheduled via launchd, see com.pricetrend.publish.plist

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA_DIR="$ROOT/product-trend-data"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_DIR="/tmp/price-trend-publish.lock"
LOG_FILE="$SCRIPT_DIR/publish.log"

RETAILERS=(
  "Chemist Warehouse Trend"
  "Bunnings Warehouse Trend"
)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG_FILE"
}

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "skip: a previous run is still in progress (found $LOCK_DIR)"
  exit 0
fi
trap 'rmdir "$LOCK_DIR"' EXIT

log "=== publish start ==="

for name in "${RETAILERS[@]}"; do
  log "export: $name"
  ( cd "$ROOT/$name" && make export-static OUT="$DATA_DIR" ) >>"$LOG_FILE" 2>&1
done

cd "$DATA_DIR"
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "data: sync $(date '+%Y-%m-%d %H:%M')" >>"$LOG_FILE" 2>&1
  git push >>"$LOG_FILE" 2>&1
  log "pushed changes"
else
  log "nothing changed, skipped push"
fi

log "=== publish done ==="

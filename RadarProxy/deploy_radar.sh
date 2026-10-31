#!/usr/bin/env bash
# Deploys RadarProxy/app.py + requirements.txt to the Mini PC (the Home
# Assistant add-on "local_weathermat_radar" — the ONLY radar backend the
# app talks to; see ../WeatherMat_Project_Overview.md §6.4), rebuilds the
# add-on, then verifies the live result over its external Cloudflare URL.
#
# This exists because `git push` does NOT deploy this proxy — a whole
# session's worth of backend fixes sat committed-but-undeployed before this
# script existed, which is exactly the "Deployment-Vergesslichkeit" this is
# meant to prevent. Run it after every RadarProxy/app.py change meant for
# the live app, not just after committing.
#
# Usage: ./deploy_radar.sh [--skip-verify]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_KEY="$HOME/.ssh/weathermat_ha_addon_deploy"
SSH_HOST="192.168.178.34"
SSH_PORT="22222"
REMOTE_DIR="/local_apps/weathermat-radar"
ADDON_SLUG="local_weathermat_radar"
EXTERNAL_URL="https://radar.praxis-hartlep.de"
LOCAL_CONFIG="$REPO_ROOT/WeatherMat/LocalConfig.plist"
# How stale /metrics' loadedAt may be right after a successful rebuild —
# the background refresh runs every 300s, so anything older here means the
# fresh deploy still isn't producing a usable cache.
MAX_LOADED_AGE_SECONDS=600

SKIP_VERIFY=false
if [[ "${1:-}" == "--skip-verify" ]]; then
  SKIP_VERIFY=true
fi

ssh_cmd() { ssh -i "$SSH_KEY" -p "$SSH_PORT" -o ConnectTimeout=10 "root@$SSH_HOST" "$@"; }

echo "==> Copying app.py + requirements.txt to the Mini PC..."
if ! scp -i "$SSH_KEY" -P "$SSH_PORT" -o ConnectTimeout=10 \
    "$SCRIPT_DIR/app.py" "$SCRIPT_DIR/requirements.txt" "root@$SSH_HOST:$REMOTE_DIR/"; then
  echo "FAILED: could not reach $SSH_HOST:$SSH_PORT. It's known to intermittently"
  echo "return 'No route to host' even when the radar service itself answers fine"
  echo "via $EXTERNAL_URL — wait a bit and retry."
  exit 1
fi

echo "==> Rebuilding add-on ($ADDON_SLUG)..."
ssh_cmd "ha apps rebuild $ADDON_SLUG"

if $SKIP_VERIFY; then
  echo "==> Skipping live verification (--skip-verify)."
  exit 0
fi

echo "==> Verifying live via $EXTERNAL_URL..."
TOKEN=""
if [[ -f "$LOCAL_CONFIG" ]]; then
  TOKEN="$(/usr/libexec/PlistBuddy -c "Print :dwdRadarTileToken" "$LOCAL_CONFIG" 2>/dev/null || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "WARNING: could not read dwdRadarTileToken from $LOCAL_CONFIG — skipping"
  echo "live verification. Check manually: curl -H 'x-radar-token: ...' $EXTERNAL_URL/metrics"
  exit 0
fi

# Poll instead of a fixed sleep: a cold rebuild's first cache build alone
# can take 15-20s (observed), on top of container restart time, so a short
# fixed wait flakes with a false "cache never built" failure.
METRICS=""
for attempt in $(seq 1 12); do
  METRICS="$(curl -sS -m 20 -H "x-radar-token: $TOKEN" "$EXTERNAL_URL/metrics" || true)"
  if echo "$METRICS" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('loadedAt') else 1)" 2>/dev/null; then
    break
  fi
  echo "    (attempt $attempt/12: cache not ready yet, waiting 10s...)"
  sleep 10
done
TIMELINE="$(curl -sS -m 20 -H "x-radar-token: $TOKEN" "$EXTERNAL_URL/timeline.json" || true)"

python3 - "$METRICS" "$TIMELINE" "$MAX_LOADED_AGE_SECONDS" <<'PYEOF'
import json
import sys
import time

metrics_raw, timeline_raw, max_age = sys.argv[1], sys.argv[2], float(sys.argv[3])
ok = True

try:
    metrics = json.loads(metrics_raw)
except Exception as error:
    print(f"FAILED: /metrics did not return valid JSON ({error}); raw response:\n{metrics_raw[:500]}")
    sys.exit(1)

loaded_at = metrics.get("loadedAt")
last_refresh_error = metrics.get("metrics", {}).get("lastRefreshError")
if loaded_at is None:
    print("FAILED: /metrics has no loadedAt — cache was never built.")
    ok = False
else:
    age = time.time() - loaded_at
    if age > max_age:
        print(f"FAILED: cache is {age/60:.1f} min old (> {max_age/60:.0f} min threshold) — "
              f"background refresh is still failing.")
        ok = False
    else:
        print(f"OK: cache is {age/60:.1f} min old.")
if last_refresh_error:
    print(f"WARNING: lastRefreshError is set: {last_refresh_error}")

try:
    timeline = json.loads(timeline_raw)
except Exception as error:
    print(f"FAILED: /timeline.json did not return valid JSON ({error})")
    sys.exit(1)

frames = timeline.get("frames", [])
max_zoom = timeline.get("tileMaxZoom")
if not frames:
    print("FAILED: /timeline.json returned no frames.")
    ok = False
else:
    print(f"OK: {len(frames)} frames, tileMaxZoom={max_zoom}, "
          f"first={frames[0]['time']}, last={frames[-1]['time']}")

sys.exit(0 if ok else 1)
PYEOF
PY_STATUS=$?

if [[ $PY_STATUS -ne 0 ]]; then
  echo "==> Deploy finished but live verification FAILED — check 'ha apps logs $ADDON_SLUG' on the host."
  exit 1
fi

echo "==> Deploy verified OK."

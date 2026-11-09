#!/usr/bin/env bash
# Deploy ONLY the verified, staged Binance completed-hour taker-ratio fallback.
# Keep the current trading container online throughout image build/tests.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077

SRC='vps/lib/engine.mjs'
STAGE='backups/staged-changes/engine-hourly-taker-20261109-182215.mjs'
LIVE_SHA='e86d9a6278752b2bb341b6bcfbfc7c318a7c729f9c8bf48b299159ca13e2e1c9'
STAGE_SHA='4dbb152d159bc2cb0d88b86d172ec2e5fbd071f555200c5645df75206dd596c1'
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$PWD/backups/hourly-taker-fallback-$STAMP"
mkdir -p "$BACKUP"

printf '%s  %s\n' "$LIVE_SHA" "$SRC" "$STAGE_SHA" "$STAGE" | sha256sum -c -
grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' "$SRC"
grep -q 'SCANNER_TOP10_RESEARCH_V1' vps/lib/desk-scanner.mjs
grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' vps/lib/research-live.mjs
# Verify the patched source does not erase existing safeguards.
grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' "$STAGE"
grep -q 'SCANNER_TOP-10 RESEARCH SLOTS' "$STAGE"
grep -q 'HOURLY_TAKER_KLINE_FALLBACK_V2' "$STAGE"
grep -q 'authorizeResearchBestEligible(applyFocusedEntry(' "$STAGE"

docker compose config --quiet
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
# Source must be image-backed; changing the host build context must not
# change code used by the still-running trading container.
docker inspect -f '{{json .Mounts}}' "$CID" | python3 -c '
import json,sys
mounts=json.load(sys.stdin)
target="/app/vps/lib/engine.mjs"
unsafe=[m.get("Destination") for m in mounts
        if m.get("Destination") and
        (target==m["Destination"] or target.startswith(m["Destination"].rstrip("/")+"/"))]
if unsafe: raise SystemExit("ABORT: engine source is live-mounted: "+str(unsafe))
print("PASS: live engine is image-backed; host staging cannot mutate running source")
'
CONTAINER_SHA="$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')"
test "$CONTAINER_SHA" = "$LIVE_SHA" || { echo 'ABORT: running engine differs from verified baseline'; exit 1; }
IMAGE_TAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
OLD_IMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
ROLLBACK="twin-desk:rollback-hourly-taker-$STAMP"
cp -a "$SRC" "$BACKUP/engine.mjs"
docker image tag "$OLD_IMAGE" "$ROLLBACK"
docker compose exec -T twin-desk cat /app/data/clean-v1-state.json > "$BACKUP/state.json"
test -s "$BACKUP/state.json"

SUCCESS=0
RESTARTED=0
recover(){
  local rc=$?
  if [ "$SUCCESS" != 1 ]; then
    echo "DEPLOYMENT ABORTED ($rc): restoring original engine and image"
    cp -a "$BACKUP/engine.mjs" "$SRC" || true
    docker image tag "$ROLLBACK" "$IMAGE_TAG" || true
    if [ "$RESTARTED" = 1 ]; then
      echo 'Recreating original container from rollback image...'
      docker compose up -d --no-deps --force-recreate twin-desk || true
    fi
    docker compose ps twin-desk || true
    echo "Backup: $BACKUP"
    echo "Rollback image: $ROLLBACK"
  fi
}
trap recover EXIT

cat > "$BACKUP/probe.mjs" <<'JS'
import fs from 'node:fs';
import {planResearchLive} from '/app/vps/lib/research-live.mjs';
const state=JSON.parse(fs.readFileSync('/audit/state.json','utf8'));
if(state.exchange?.connected!==true || state.exchange?.positionsStale!==false)
  throw Error('Saved Binance exchange snapshot is disconnected or stale; refusing deployment');
const direct=Object.values(state.directBinance?.orders||{});
const pending=direct.filter(o=>['claimed','sending','outcome_unknown'].includes(o?.status));
if(pending.length)throw Error(`Unresolved direct opening/order claims: ${pending.length}`);
const stamp=Date.parse(state.exchange?.at||state.exchange?.asOf||'');
const plan=planResearchLive(structuredClone(state),{now:Number.isFinite(stamp)?stamp:Date.now()});
if(!Array.isArray(plan?.orders))throw Error('Unexpected position-planner response');
const ybusdtOpening=plan.orders.some(o=>o.symbol==='YBUSDT'&&!o.reduce);
if(ybusdtOpening)throw Error('Stale YBUSDT opening would be planned');
const reductions=plan.orders.filter(o=>o.reduce).map(o=>({
  symbol:o.symbol,side:o.side,qty:o.qty
})).sort((a,b)=>a.symbol.localeCompare(b.symbol)||a.side.localeCompare(b.side));
const engine=fs.readFileSync('/app/vps/lib/engine.mjs','utf8');
console.log('FLOW_DEPLOY_PROBE='+JSON.stringify({
  installed:engine.includes('HOURLY_TAKER_KLINE_FALLBACK_V2'),
  bestEligible:engine.includes('BEST_ELIGIBLE_EXPECTED_PROFIT_V1'),
  ybusdtOpening,reductions,
  exchangePositions:Array.isArray(state.exchange?.positions)?state.exchange.positions.length:null
}));
JS
probe(){
  docker run --rm -i --network none --read-only --user 0 \
    -v "$BACKUP/state.json:/audit/state.json:ro" \
    --entrypoint node "$IMAGE_TAG" --input-type=module < "$BACKUP/probe.mjs"
}

echo '=== BASELINE: OFFLINE POSITION PROTECTION AND ORDER PLAN ==='
probe > "$BACKUP/before.txt"
python3 - "$BACKUP/before.txt" <<'PY'
import json,sys
rows=[json.loads(x.split('=',1)[1]) for x in open(sys.argv[1]) if x.startswith('FLOW_DEPLOY_PROBE=')]
assert len(rows)==1 and not rows[0]['installed'] and rows[0]['bestEligible']
assert not rows[0]['ybusdtOpening']
print('PASS: old-image planner, Gemini selection and YBUSDT protection')
print('Exchange positions in snapshot:',rows[0]['exchangePositions'])
PY

echo '=== INSTALL VERIFIED SOURCE INTO BUILD CONTEXT ONLY ==='
install -m 0644 "$STAGE" "$SRC"
printf '%s  %s\n' "$STAGE_SHA" "$SRC" | sha256sum -c -

echo '=== BUILD NEW IMAGE WHILE LIVE CONTAINER CONTINUES RUNNING ==='
docker compose build twin-desk
NEW_IMAGE="$(docker image inspect -f '{{.Id}}' "$IMAGE_TAG")"
test "$NEW_IMAGE" != "$OLD_IMAGE"
for f in engine research-top1-entry research-live desk-scanner; do
  docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" \
    --check "/app/vps/lib/$f.mjs"
done
docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" \
  -e "const fs=require('node:fs'); const e=fs.readFileSync('/app/vps/lib/engine.mjs','utf8'); if(!e.includes('HOURLY_TAKER_KLINE_FALLBACK_V2')||!e.includes('BEST_ELIGIBLE_EXPECTED_PROFIT_V1')) process.exit(1); const l=fs.readFileSync('/app/vps/lib/research-live.mjs','utf8'); if(!l.includes('STALE_RESEARCH_REOPEN_GUARD_V1')) process.exit(1);"

echo '=== OFFLINE BEFORE/AFTER POSITION PLAN COMPARISON ==='
probe > "$BACKUP/after.txt"
python3 - "$BACKUP/before.txt" "$BACKUP/after.txt" <<'PY'
import sys,json

def read(path):
  rows=[json.loads(x.split('=',1)[1]) for x in open(path) if x.startswith('FLOW_DEPLOY_PROBE=')]
  assert len(rows)==1, 'Missing offline probe output'
  return rows[0]
a,b=map(read,sys.argv[1:]);assert not a['installed'] and b['installed']
assert a['bestEligible'] and b['bestEligible']
assert a['reductions']==b['reductions'],'Existing reduction plans changed'
assert not a['ybusdtOpening'] and not b['ybusdtOpening']
print('PASS: same snapshot, identical planned position reductions')
print('PASS: YBUSDT reopening stays blocked')
PY

echo '=== FINAL LIVE-SAFETY PREFLIGHT ==='
# Check the currently running trading engine is still healthy just before restart.
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
if(s.exchange?.connected!==true||s.exchange?.positionsStale!==false)
  throw Error('Live Binance snapshot disconnected/stale');
const pending=Object.values(s.directBinance?.orders||{}).filter(o=>
  ['claimed','sending','outcome_unknown'].includes(o?.status));
if(pending.length)throw Error('Outstanding direct order claims; no restart');
console.log('PASS: live Binance snapshot connected and no unresolved direct-order claims');
JS

echo '=== CONTROLLED CONTAINER RECREATE ==='
RESTARTED=1
docker compose up -d --no-deps --force-recreate twin-desk
HEALTH=starting
for i in $(seq 1 60); do
  CID="$(docker compose ps -q twin-desk)"
  test -n "$CID"
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID")"
  if [ "$HEALTH" = healthy ]; then break; fi
  if [ "$HEALTH" = unhealthy ] || [ "$HEALTH" = exited ]; then break; fi
  sleep 2
done
test "$HEALTH" = healthy

docker compose exec -T twin-desk grep -q 'HOURLY_TAKER_KLINE_FALLBACK_V2' /app/vps/lib/engine.mjs
docker compose exec -T twin-desk grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' /app/vps/lib/engine.mjs
docker compose exec -T twin-desk grep -q 'SCANNER_TOP10_RESEARCH_V1' /app/vps/lib/desk-scanner.mjs
docker compose exec -T twin-desk grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' /app/vps/lib/research-live.mjs
RUN_IMAGE="$(docker inspect -f '{{.Image}}' "$(docker compose ps -q twin-desk)")"
test "$RUN_IMAGE" = "$NEW_IMAGE"
SUCCESS=1
trap - EXIT

echo 'SUCCESS: VERIFIED HOURLY TAKER FALLBACK DEPLOYED'
echo 'Note: scanner refresh is asynchronous; new ratios must be checked after the next scan.'
echo "Backup: $BACKUP"
echo "Rollback image: $ROLLBACK"
docker compose ps twin-desk
#!/usr/bin/env bash
# Deploy verified compact Gemini prompt parity without modifying trading or execution modules.
# Keep the current trading container online throughout image build/tests.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077

SRC='vps/lib/engine.mjs'
STAGE='backups/staged-changes/engine-compact-policy-parity-20261110-204848.mjs'
LIVE_SHA='14f0499bb4acd7f435131063c9f1b7abca85920c3c0f741d42c0309e3abf01f2'
STAGE_SHA='eb98f6a0638adf75ddef64b547fe1d7ab20af0c399e7f88fe0934fa29291e5c2'
ENTRY_SHA='0719fe0d37282e77b9de5fcb7e1da016e5b124e210e27c98aed70208032fc4b2'
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$PWD/backups/compact-prompt-parity-$STAMP"
mkdir -p "$BACKUP"
printf '%s  %s\n' "$LIVE_SHA" "$SRC" "$STAGE_SHA" "$STAGE" "$ENTRY_SHA" "vps/lib/research-top1-entry.mjs" | sha256sum -c -
! grep -Fq 'COMPACT_PRIMARY_POLICY_PARITY_V1' "$SRC"
grep -Fq 'COMPACT_PRIMARY_POLICY_PARITY_V1' "$STAGE"
for term in COMPACT_ATLAS_MOMENTUM_V1 COMPACT_ORACLE_REVERSION_V1 COMPACT_SCANNER_ADVISORY_V1 COMPACT_PEER_EVIDENCE_V1; do
  grep -Fq "$term" "$STAGE"
done
! grep -Fq 'scannerResearchOnlySymbols is NOT READY' "$STAGE"
! grep -Fq 'a research-only scanner candidate always HOLDs.' "$STAGE"
grep -Fq 'scannerReadinessObservations:' "$STAGE"
grep -Fq 'SCANNER_SHORTLIST_ONLY_V1' vps/lib/research-top1-entry.mjs
grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' "$SRC"
grep -q 'SCANNER_TOP10_RESEARCH_V1' vps/lib/desk-scanner.mjs
grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' vps/lib/research-live.mjs
# Verify the patched source does not erase existing safeguards.
grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' "$STAGE"
grep -Fq 'SCANNER TOP-10 RESEARCH SLOTS' "$STAGE"
grep -Fq 'HOURLY_TAKER_KLINE_FALLBACK_V2' "$STAGE"
grep -Fq 'PROMPT_CONSISTENCY_BEST_ELIGIBLE_V2' "$STAGE"
grep -Fq 'INDEPENDENT_DESKS_PEER_CHALLENGE_V1' "$STAGE"
grep -Fq 'INDEPENDENT_PEER_EVIDENCE_V1' "$STAGE"
grep -Fq 'ATLAS–ORACLE TWO-WAY DIALOGUE V2' "$STAGE"
! grep -Fq 'Do not trade a lower-ranked coin instead.' "$STAGE"
grep -Fq 'authorizeResearchBestEligible(applyFocusedEntry(' "$STAGE"

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
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-top1-entry.mjs | awk '{print $1}')" = "$ENTRY_SHA"
echo '=== VERIFY RESEARCH AUTHORITY AND MARKET SAFETY SETTINGS ==='
docker compose exec -T twin-desk node --input-type=module <<'JS'
for(const [key,expect] of [
  ['RESEARCH_TOP1_ENTRY_ENABLED','true'],
  ['SCANNER_AUTO_ENTRY_ENABLED','false'],
  ['PRE_ENTRY_MICRO_CHECK_ENABLED','true']
])if(process.env[key]!==expect)throw Error('ABORT: '+key+' must equal '+expect);
console.log('PASS: Gemini research entry authority and independent market quality gate enabled');
JS
echo '=== PREVENT NEW ENTRIES THROUGH ENGINE CONTROL ==='
INITIAL_PAUSED="$(docker compose exec -T twin-desk node -e "const s=require('/app/data/clean-v1-state.json');process.stdout.write(s.livePaused===true?'true':'false')")"
test "$INITIAL_PAUSED" = true || test "$INITIAL_PAUSED" = false
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
await setEntriesPaused(true);
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
if(s.livePaused!==true)throw Error('Cannot verify entry pause');
console.log('PASS: new entries paused; existing-position management unchanged');
JS
echo 'On any failure, keep entries paused until exchange safety is rechecked.'
echo '=== VERIFY VERIFIED-FLAT EXCHANGE STATE ==='
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const e=s.exchange||{};
const t=Date.parse(e.at||e.asOf||'');
if(s.tradingControl?.status!=='running'||s.livePaused!==true)
  throw Error('Active trading session not confirmed paused');
if(e.connected!==true||e.positionsStale!==false||
   !Number.isFinite(t)||Date.now()-t>300000||t>Date.now()+15000)
  throw Error('Binance exchange snapshot is not verified and fresh');
if(e.algoOrdersSupported!==true||
   !Array.isArray(e.positions)||e.positions.length||
   !Array.isArray(e.openOrders)||e.openOrders.length||
   !Array.isArray(e.algoOrders)||e.algoOrders.length)
  throw Error('Exchange must be fully flat with zero ordinary and conditional orders');
if(s.pendingOrders && (!Array.isArray(s.pendingOrders)||s.pendingOrders.length))
  throw Error('Pending orders exist');
if(s.executionIssue)throw Error('Execution issue exists');
const unresolved=Object.values(s.directBinance?.orders||{})
 .filter(o=>['claimed','sending','outcome_unknown'].includes(o?.status));
if(unresolved.length)throw Error('Unresolved direct order claims');
console.log('PASS: fresh, verified-flat Binance Demo state and no outstanding orders');
JS
IMAGE_TAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
OLD_IMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
ROLLBACK="twin-desk:rollback-compact-prompt-$STAMP"
cp -a "$SRC" "$BACKUP/engine.mjs"
docker image tag "$OLD_IMAGE" "$ROLLBACK"
docker compose exec -T twin-desk cat /app/data/clean-v1-state.json > "$BACKUP/state.json"
test -s "$BACKUP/state.json"

SUCCESS=0
RESTARTED=0
recover(){
  local rc=$?
  if [ "$SUCCESS" != 1 ]; then
    echo "DEPLOYMENT ABORTED ($rc): restoring original engine and image; entries remain PAUSED"
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
const compactMarkers=['COMPACT_PRIMARY_POLICY_PARITY_V1','COMPACT_ATLAS_MOMENTUM_V1','COMPACT_ORACLE_REVERSION_V1','COMPACT_SCANNER_ADVISORY_V1','COMPACT_PEER_EVIDENCE_V1'];
const entry=fs.readFileSync('/app/vps/lib/research-top1-entry.mjs','utf8');
console.log('FLOW_DEPLOY_PROBE='+JSON.stringify({
  installed:compactMarkers.every(marker=>engine.includes(marker)) &&
    !engine.includes('scannerResearchOnlySymbols is NOT READY') &&
    !engine.includes('a research-only scanner candidate always HOLDs.'),
  scannerAdvisory:engine.includes('scannerReadinessObservations:') && entry.includes('SCANNER_SHORTLIST_ONLY_V1'),
  peerResearchRetained:engine.includes('INDEPENDENT_DESKS_PEER_CHALLENGE_V1') &&
      engine.includes('INDEPENDENT_PEER_EVIDENCE_V1'),
  peerDialogue:engine.includes('ATLAS–ORACLE TWO-WAY DIALOGUE V2'),
  hourlyFlowFix:engine.includes('HOURLY_TAKER_KLINE_FALLBACK_V2'),
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
assert len(rows)==1 and not rows[0]['installed'] and rows[0]['bestEligible'] and rows[0]['hourlyFlowFix'] and rows[0]['peerDialogue'] and rows[0]['scannerAdvisory'] and rows[0]['peerResearchRetained']
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
echo '=== VERIFY UNCHANGED EXECUTION SAFETY MODULES ==='
for f in research-top1-entry research-live desk-scanner research-to-binance research-leverage-guard gemini-fallback; do
  BEFORE="$(docker compose exec -T twin-desk sha256sum "/app/vps/lib/$f.mjs" | awk '{print $1}')"
  AFTER="$(docker run --rm --network none --read-only --entrypoint sha256sum "$IMAGE_TAG" "/app/vps/lib/$f.mjs" | awk '{print $1}')"
  test "$BEFORE" = "$AFTER" || { echo "ABORT: safety module changed: $f"; exit 1; }
  echo "PASS: unchanged $f"
done
docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" \
  -e "const fs=require('node:fs'); const e=fs.readFileSync('/app/vps/lib/engine.mjs','utf8'); if(!e.includes('HOURLY_TAKER_KLINE_FALLBACK_V2')||!e.includes('PROMPT_CONSISTENCY_BEST_ELIGIBLE_V2')||!e.includes('INDEPENDENT_DESKS_PEER_CHALLENGE_V1')||!e.includes('INDEPENDENT_PEER_EVIDENCE_V1')||!e.includes('BEST_ELIGIBLE_EXPECTED_PROFIT_V1')||e.includes('Do not trade a lower-ranked coin instead.')) process.exit(1);
for(const mark of ['COMPACT_PRIMARY_POLICY_PARITY_V1','COMPACT_ATLAS_MOMENTUM_V1','COMPACT_ORACLE_REVERSION_V1','COMPACT_SCANNER_ADVISORY_V1','COMPACT_PEER_EVIDENCE_V1'])
  if(!e.includes(mark))process.exit(1);
if(e.includes('scannerResearchOnlySymbols is NOT READY')||e.includes('a research-only scanner candidate always HOLDs.')) process.exit(1);
const g=fs.readFileSync('/app/vps/lib/gemini-fallback.mjs','utf8');
if(!g.includes('const requestBody = (isFallback || compactPrimary) && fallbackBody ? fallbackBody : body;') || !e.includes('compactPrimary:compactPrimary || researchMode'))process.exit(1); const l=fs.readFileSync('/app/vps/lib/research-live.mjs','utf8'); if(!l.includes('STALE_RESEARCH_REOPEN_GUARD_V1')) process.exit(1);"

echo '=== OFFLINE BEFORE/AFTER POSITION PLAN COMPARISON ==='
probe > "$BACKUP/after.txt"
python3 - "$BACKUP/before.txt" "$BACKUP/after.txt" <<'PY'
import sys,json

def read(path):
  rows=[json.loads(x.split('=',1)[1]) for x in open(path) if x.startswith('FLOW_DEPLOY_PROBE=')]
  assert len(rows)==1, 'Missing offline probe output'
  return rows[0]
a,b=map(read,sys.argv[1:]);assert not a['installed'] and b['installed']
assert a['bestEligible'] and b['bestEligible'] and a['hourlyFlowFix'] and b['hourlyFlowFix'] and a['peerDialogue'] and b['peerDialogue'] and a['scannerAdvisory'] and b['scannerAdvisory'] and a['peerResearchRetained'] and b['peerResearchRetained']
assert a['reductions']==b['reductions'],'Existing reduction plans changed'
assert not a['ybusdtOpening'] and not b['ybusdtOpening']
print('PASS: same snapshot, identical planned position reductions')
print('PASS: YBUSDT reopening stays blocked')
print('PASS: completed-hour taker-flow correction retained')
print('PASS: compact research guidance added only in staged image')
PY

echo '=== FINAL LIVE-SAFETY PREFLIGHT ==='
# Check the currently running trading engine is still healthy just before restart.
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const e=s.exchange||{};
const t=Date.parse(e.at||e.asOf||'');
if(s.tradingControl?.status!=='running'||s.livePaused!==true)
  throw Error('Trading session must remain running but paused');
if(e.connected!==true||e.positionsStale!==false||
   !Number.isFinite(t)||Date.now()-t>300000||t>Date.now()+15000)
  throw Error('Live Binance snapshot disconnected/stale');
if(e.algoOrdersSupported!==true||
   !Array.isArray(e.positions)||e.positions.length||
   !Array.isArray(e.openOrders)||e.openOrders.length||
   !Array.isArray(e.algoOrders)||e.algoOrders.length)
  throw Error('Binance Demo must remain flat with zero orders');
if(s.pendingOrders && (!Array.isArray(s.pendingOrders)||s.pendingOrders.length))
  throw Error('Pending orders detected');
if(s.executionIssue)throw Error('Execution issue detected');
const pending=Object.values(s.directBinance?.orders||{}).filter(o=>
  ['claimed','sending','outcome_unknown'].includes(o?.status));
if(pending.length)throw Error('Outstanding direct order claims; no restart');
console.log('PASS: live exchange snapshot fresh, fully flat and no unresolved direct-order claims');
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
docker compose exec -T twin-desk grep -q 'PROMPT_CONSISTENCY_BEST_ELIGIBLE_V2' /app/vps/lib/engine.mjs
docker compose exec -T twin-desk grep -q 'INDEPENDENT_DESKS_PEER_CHALLENGE_V1' /app/vps/lib/engine.mjs
docker compose exec -T twin-desk grep -q 'INDEPENDENT_PEER_EVIDENCE_V1' /app/vps/lib/engine.mjs
docker compose exec -T twin-desk grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' /app/vps/lib/engine.mjs
for marker in COMPACT_PRIMARY_POLICY_PARITY_V1 COMPACT_ATLAS_MOMENTUM_V1 COMPACT_ORACLE_REVERSION_V1 COMPACT_SCANNER_ADVISORY_V1 COMPACT_PEER_EVIDENCE_V1; do
  docker compose exec -T twin-desk grep -Fq "$marker" /app/vps/lib/engine.mjs
done
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')" = "$STAGE_SHA"
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-top1-entry.mjs | awk '{print $1}')" = "$ENTRY_SHA"
docker compose exec -T twin-desk node --input-type=module <<'JS'
for(const [key,expect] of [
  ['RESEARCH_TOP1_ENTRY_ENABLED','true'],
  ['SCANNER_AUTO_ENTRY_ENABLED','false'],
  ['PRE_ENTRY_MICRO_CHECK_ENABLED','true']
])if(process.env[key]!==expect)throw Error('Safety config changed: '+key);
console.log('PASS: critical execution quality settings unchanged after restart');
JS
docker compose exec -T twin-desk grep -q 'SCANNER_TOP10_RESEARCH_V1' /app/vps/lib/desk-scanner.mjs
docker compose exec -T twin-desk grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' /app/vps/lib/research-live.mjs
RUN_IMAGE="$(docker inspect -f '{{.Image}}' "$(docker compose ps -q twin-desk)")"
test "$RUN_IMAGE" = "$NEW_IMAGE"
echo '=== REVALIDATE EXCHANGE FLATNESS AFTER RECREATE ==='
READY=0
for i in $(seq 1 40); do
  if docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const e=s.exchange||{}, t=Date.parse(e.at||e.asOf||'');
const unresolved=Object.values(s.directBinance?.orders||{})
 .filter(o=>['claimed','sending','outcome_unknown'].includes(o?.status));
if(s.tradingControl?.status!=='running'||s.livePaused!==true||
   e.connected!==true||e.positionsStale!==false||
   !Number.isFinite(t)||Date.now()-t>300000||t>Date.now()+15000||
   e.algoOrdersSupported!==true||
   !Array.isArray(e.positions)||e.positions.length||
   !Array.isArray(e.openOrders)||e.openOrders.length||
   !Array.isArray(e.algoOrders)||e.algoOrders.length||
   (s.pendingOrders && (!Array.isArray(s.pendingOrders)||s.pendingOrders.length))||
   s.executionIssue||unresolved.length)process.exit(1);
console.log('PASS: post-restart exchange snapshot remains verified flat');
JS
  then READY=1; break; fi
  sleep 2
done
test "$READY" = 1 || { echo 'ABORT: exchange readiness could not be reverified; leaving entries paused'; exit 1; }
if [ "$INITIAL_PAUSED" = false ]; then
  echo '=== RESTORE PREVIOUSLY ENABLED DEMO TRADING ==='
  docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
await setEntriesPaused(false);
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
if(s.livePaused!==false||s.tradingControl?.status!=='running')
  throw Error('Could not verify restored entry permission');
console.log('PASS: Atlas and Oracle entry permissions restored');
JS
else
  echo 'PASS: prior operator pause preserved (trading remains paused)'
fi
SUCCESS=1
trap - EXIT

echo 'SUCCESS: COMPACT GEMINI STRATEGY AND SCANNER-ADVISORY PROMPTS DEPLOYED'
echo 'Note: post-deployment Gemini research quality remains to be observed; exchange-hosted stops remain unverified.'
echo "Backup: $BACKUP"
echo "Rollback image: $ROLLBACK"
docker compose ps twin-desk
#!/usr/bin/env bash
# REC_BRACKET_HANDOFF_V1 — audited 2026-11-11 engine only; fail closed.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077
SRC=vps/lib/engine.mjs
BASE=f788003d4ad5b3f2559db0528fc47021f5e075013f659a8a3b75b3a63c55c86f
TS=$(date -u +%Y%m%d-%H%M%S)
BACK="$PWD/backups/bracket-handoff-$TS"
ROLLBACK="twin-desk:rollback-bracket-handoff-$TS"

echo '=== VERIFY EXACT ENGINE, DOCKER AND RESEARCH CONTROLS ==='
printf '%s  %s\n' "$BASE" "$SRC" | sha256sum -c -
docker compose config --quiet
CID=$(docker compose ps -q twin-desk)
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')" = "$BASE"
docker inspect -f '{{json .Mounts}}' "$CID" | python3 -c '
import json,sys
mounts=json.load(sys.stdin); t="/app/vps/lib/engine.mjs"
assert not any((p:=m.get("Destination","")) and (p==t or t.startswith(p.rstrip("/")+"/")) for m in mounts),"ABORT: engine is live-mounted"
print("PASS: engine is image-backed")'
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const ok=(x,m)=>{if(!x)throw Error('ABORT: '+m)};
for(const [k,v] of [['RESEARCH_TOP1_ENTRY_ENABLED','true'],['SCANNER_AUTO_ENTRY_ENABLED','false'],['PRE_ENTRY_MICRO_CHECK_ENABLED','true'],['LIVE_STRATEGY','research-both']])ok(process.env[k]===v,k);
ok(s.tradingControl?.status==='running'&&s.livePaused===false,'trading must start enabled');
ok(e.connected===true&&e.positionsStale===false,'exchange not connected');
const age=Date.now()-Date.parse(e.at||'');ok(age>=0&&age<=300000,'exchange stale');
ok(Array.isArray(e.positions)&&!e.positions.length,'exchange not flat');
ok(Array.isArray(e.openOrders)&&!e.openOrders.length,'regular orders pending');
ok(Array.isArray(e.algoOrders)&&!e.algoOrders.length,'conditional orders pending');
ok(!s.pendingOrders?.length&&!s.executionIssue,'pending/unknown order');
ok(!Object.values(s.directBinance?.orders||{}).some(o=>['claimed','sending','outcome_unknown'].includes(o?.status)),'direct order unresolved');
const endpoints=Object.entries(process.env).filter(([k])=>/(BINANCE|FUTURES)/i.test(k)&&/(BASE|HOST|URL|ENDPOINT)/i.test(k)).map(([,v])=>String(v||''));
ok(!endpoints.some(u=>/(?:^|\/\/)fapi\.binance\.com(?:\/|$)/i.test(u)),'production endpoint');
console.log('PASS: enabled research-both, verified flat exchange and no unresolved orders');
JS

echo '=== PREPARE PRECISE SOURCE PATCH ==='
mkdir -p "$BACK"
python3 - "$SRC" "$BACK/engine.staged.mjs" "$BASE" <<'PY'
from pathlib import Path
import hashlib,sys
src=Path(sys.argv[1]).read_text(); dst=Path(sys.argv[2])
assert hashlib.sha256(src.encode()).hexdigest()==sys.argv[3]
assert 'REC_BRACKET_HANDOFF_V1' not in src
shadow=Path('vps/lib/shadow-futures.mjs').read_text()
guard=Path('vps/lib/research-leverage-guard.mjs').read_text()
assert 'leverageRules:options.leverageRules' in shadow
assert 'call.size>=0.10&&call.size<=0.20' in shadow
for k in ['MAX_BRACKET_AGE_MS = 150000','leverage_brackets_stale_or_missing','above_exchange_notional_bracket_maximum','leverageRules?.bySymbol?.[symbol]','leverageRules?.at']:
 assert k in guard,k
p='    const result={version:1,id,at:finishedAt,started,inferenceMs,modelRouteBudgetMs:timeout,\n'
p1=p+'      // REC_BRACKET_HANDOFF_V1: same signed account-specific rules used by the model gate.\n      entryLeverageRules:market.leverageRules||null,\n'
a='positionContext:proposal.positionContext,inputMarketAsOf:proposal.inputMarketAsOf,currentMarket:{marks:state.market?.marks||{},snapshot:state.market}});'
a1='positionContext:proposal.positionContext,inputMarketAsOf:proposal.inputMarketAsOf,currentMarket:{marks:state.market?.marks||{},snapshot:state.market,leverageRules:proposal.entryLeverageRules||null}});'
r='    applyResearchResponse(state.desks.atlas,managementOnly(atlas),{marks,snapshot:currentMarket?.snapshot || state.market});\n    applyResearchResponse(state.desks.oracle,managementOnly(oracle),{marks,snapshot:currentMarket?.snapshot || state.market});\n'
r1='    // REC_BRACKET_HANDOFF_V1: repeat signed bracket checks at Clerk commit time.\n    const entryContext={marks,snapshot:currentMarket?.snapshot || state.market,\n      leverageRules:currentMarket?.leverageRules||null,exchangePositions:state.exchange?.positions||[]};\n    applyResearchResponse(state.desks.atlas,managementOnly(atlas),entryContext);\n    applyResearchResponse(state.desks.oracle,managementOnly(oracle),entryContext);\n'
for label,old in [('proposal',p),('adoption',a),('entry',r)]:
 assert src.count(old)==1,f'ABORT: changed {label} anchor count={src.count(old)}'
patch=src.replace(p,p1,1).replace(a,a1,1).replace(r,r1,1)
assert patch.replace(r1,r,1).replace(a1,a,1).replace(p1,p,1)==src,'nonreversible change'
for marker in ['BEST_ELIGIBLE_EXPECTED_PROFIT_V1','ATLAS_BIDIRECTIONAL_TREND_V2','UNCOMPRESSED_SYMBOL_FLOW_V1','UNCOMPRESSED_SYMBOL_PRICES_V1']:
 assert marker in patch,marker
assert patch.count('REC_BRACKET_HANDOFF_V1')==2
dst.write_text(patch)
print('PASS: all three anchors, checks, strategy policies and 150s guard preserved')
print('STAGED SHA256:',hashlib.sha256(patch.encode()).hexdigest())
PY
docker compose exec -T twin-desk node --check --input-type=module < "$BACK/engine.staged.mjs"
PATCHSHA=$(sha256sum "$BACK/engine.staged.mjs" | awk '{print $1}')
cp -a "$SRC" "$BACK/engine.original.mjs"
ORIGINAL_IMAGE=$(docker inspect -f '{{.Image}}' "$CID")
IMAGE_TAG=$(docker inspect -f '{{.Config.Image}}' "$CID")
docker image tag "$ORIGINAL_IMAGE" "$ROLLBACK"
docker compose exec -T twin-desk cat /app/data/clean-v1-state.json > "$BACK/state.json"
test -s "$BACK/state.json"

echo '=== PAUSE NEW ENTRIES FOR DEPLOYMENT ==='
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
await setEntriesPaused(true);
if(JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')).livePaused!==true)throw Error('ABORT: cannot verify pause');
console.log('PASS: entries paused');
JS
COMPLETE=0
RECREATED=0
recover(){
  rc=$?
  if [ "$COMPLETE" != 1 ]; then
    echo "FAIL: exit $rc; restoring original engine/image. ENTRIES REMAIN PAUSED."
    cp -a "$BACK/engine.original.mjs" "$SRC" || true
    docker image tag "$ROLLBACK" "$IMAGE_TAG" || true
    if [ "$RECREATED" = 1 ]; then docker compose up -d --no-deps --force-recreate twin-desk || true; fi
    echo "Rollback image: $ROLLBACK"
    echo "Backup: $BACK"
  fi
}
trap recover EXIT

echo '=== RECHECK PAUSED AND FLAT ==='
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=Date.now()-Date.parse(e.at||'');
if(s.livePaused!==true||e.connected!==true||e.positionsStale!==false||!(age>=0&&age<=300000)||!Array.isArray(e.positions)||e.positions.length||!Array.isArray(e.openOrders)||e.openOrders.length||!Array.isArray(e.algoOrders)||e.algoOrders.length||s.pendingOrders?.length||s.executionIssue)throw Error('ABORT: exchange not verified flat');
console.log('PASS: paused and flat');
JS
cp -a "$BACK/engine.staged.mjs" "$SRC"
printf '%s  %s\n' "$PATCHSHA" "$SRC" | sha256sum -c -

echo '=== BUILD AND START PATCHED ENGINE ==='
docker compose build twin-desk
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')" = "$BASE"
RECREATED=1
docker compose up -d --no-deps --force-recreate twin-desk
NEWCID=$(docker compose ps -q twin-desk)
test -n "$NEWCID"
for _ in $(seq 1 48); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID" 2>/dev/null || true)" = healthy ] && break
  sleep 5
done
test "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID")" = healthy
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')" = "$PATCHSHA"

echo '=== WAIT FOR FRESH SCANNER AND EXCHANGE POST-RESTART ==='
STARTED=$(docker inspect -f '{{.State.StartedAt}}' "$NEWCID")
cat > "$BACK/gate.mjs" <<'JS'
import fs from 'node:fs';const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const now=Date.now(),age=x=>now-Date.parse(x||'');
const ready=s.livePaused===true&&s.tradingControl?.status==='running'&&e.connected===true&&e.positionsStale===false&&
  age(e.at)>=0&&age(e.at)<=300000&&age(s.market?.asOf)>=0&&age(s.market?.asOf)<=300000&&
  Date.parse(s.market?.asOf||'')>=Date.parse(process.env.ENGINE_STARTED||'')&&Object.keys(s.market?.symbols||{}).length>0&&
  Array.isArray(e.positions)&&!e.positions.length&&Array.isArray(e.openOrders)&&!e.openOrders.length&&
  Array.isArray(e.algoOrders)&&!e.algoOrders.length&&!s.pendingOrders?.length&&!s.executionIssue&&
  !Object.values(s.directBinance?.orders||{}).some(o=>['claimed','sending','outcome_unknown'].includes(o?.status));
console.log(JSON.stringify({ready,entriesPaused:s.livePaused,marketAgeSec:Math.round(age(s.market?.asOf)/1000),exchangeAgeSec:Math.round(age(e.at)/1000)}));
process.exit(ready?0:10);
JS
READY=0
for _ in $(seq 1 48); do
  if docker compose exec -T -e ENGINE_STARTED="$STARTED" twin-desk node --input-type=module < "$BACK/gate.mjs"; then READY=1; break; fi
  sleep 15
done
test "$READY" = 1 || { echo 'ABORT: fresh post-restart snapshots unavailable'; exit 1; }

echo '=== RESTORE OPERATOR-REQUESTED ENABLED ENTRIES ==='
docker compose exec -T -e ENGINE_STARTED="$STARTED" twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
const read=()=>JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const s=read(),e=s.exchange||{},age=x=>Date.now()-Date.parse(x||'');
if(s.livePaused!==true||s.tradingControl?.status!=='running'||!e.connected||e.positionsStale||
  !(age(e.at)>=0&&age(e.at)<=300000)||!(age(s.market?.asOf)>=0&&age(s.market?.asOf)<=300000)||
  Date.parse(s.market?.asOf||'')<Date.parse(process.env.ENGINE_STARTED||'')||
  (e.positions||[]).length||(e.openOrders||[]).length||(e.algoOrders||[]).length||s.pendingOrders?.length||s.executionIssue)throw Error('ABORT: reactivation gate failed');
await setEntriesPaused(false);
if(read().livePaused!==false)throw Error('ABORT: activation not retained');
console.log('PASS: Demo entries enabled, original leverage and risk checks retained');
JS
COMPLETE=1
trap - EXIT
echo '=== RESEARCH BRACKET HANDOFF DEPLOYMENT COMPLETE ==='
echo "Patched engine SHA256: $PATCHSHA"
echo 'Atlas: bidirectional momentum; Oracle: mean reversion'
echo 'New entries: ENABLED; execution requires independent risk gates'
echo 'Signed bracket freshness: original 150-second fail-closed limit'
echo 'Software-only protection remains unchanged; not guaranteed during downtime'
echo "Backup: $BACK"
echo "Rollback image: $ROLLBACK"
docker compose ps twin-desk

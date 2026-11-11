#!/usr/bin/env bash
# HOLDER_FIRST_V1 — no source archive upload; patches only verified local VPS code.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077
BASE=f7dfe635476d3b131221efbbc547f677461185886349c87b1da0683644004133
SRC=vps/lib/research-live.mjs
HELP=vps/lib/research-holder-first.mjs
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACK="$PWD/backups/holder-first-$STAMP"
mkdir -p "$BACK"
echo '=== EXACT ENGINE AND RESEARCH PLANNER PREFLIGHT ==='
printf '%s  vps/lib/engine.mjs\n' "$BASE" | sha256sum -c -
docker compose config --quiet
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/engine.mjs | awk '{print $1}')" = "$BASE"
OLD_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
test "$OLD_SHA" = 188c0c96487ed7971828056772dcaaef6ca33f985bf28f9982bf864b8883154c || {
  echo 'ABORT: research planner is not the previously inspected version'
  exit 1
}
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-live.mjs | awk '{print $1}')" = "$OLD_SHA"
test ! -e "$HELP"
cp -a "$SRC" "$BACK/research-live.original.mjs"
echo "PASS: host/container source identical ($OLD_SHA)"
cat > "$BACK/research-holder-first.mjs" <<'JS'
// HOLDER_FIRST_V1: an independent desk cannot silently net away a peer's live coin.
// Only the holder's own research-book management can reduce/close it.
// Emergency research-exit blocks remain outside this function and take precedence.
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const sign=n=>Math.sign(Number(n)||0);
const parsed=x=>Date.parse(x||'');
const fresh=x=>Number.isFinite(parsed(x));
function originalOwner(state,symbol,direction){
  const claims=Object.values(state.directBinance?.orders||{}).filter(o=>
    o?.symbol===symbol && ['filled','partial'].includes(o.status) &&
    !o.reduceOnly && o.researchMirror?.contributions?.length && fresh(o.createdAt)
  ).sort((a,b)=>parsed(a.createdAt)-parsed(b.createdAt));
  for(const claim of claims){
    if(sign(claim.side==='BUY'?1:-1)!==direction)continue;
    const contributed=claim.researchMirror.contributions.filter(c=>finite(c.qty)&&sign(c.qty)===direction&&c.qty);
    if(contributed.length===1)return contributed[0].desk;
  }
  return null;
}
function released(state,owner,symbol,requestAt,now){
  const requested=parsed(requestAt);
  if(!Number.isFinite(requested))return false;
  const assessment=state.desks?.[owner]?.last?.researchAssessments?.find(x=>x.symbol===symbol);
  if(assessment && ['close','close_all'].includes(String(assessment.action||'').toLowerCase()) &&
     parsed(assessment.at)>=requested && parsed(assessment.at)<=now+5000)return true;
  return (state.desks?.[owner]?.futuresShadow?.trades||[]).some(x=>
    x.symbol===symbol && x.intent==='close' &&
    ['model','model_protection'].includes(x.authority) && parsed(x.at)>=requested && parsed(x.at)<=now+5000);
}
export function holderFirstTarget(state,mirror,symbol,contributions,current,now=Date.now()){
  const desired=contributions.reduce((n,c)=>n+Number(c.qty||0),0);
  if(!finite(current)||contributions.some(c=>!finite(c.qty)))return {qty:current||0,reason:`${symbol}: invalid quantity, freeze normal reconciliation`};
  mirror.holderFirst ||= {version:1,owners:{},challenges:{}};
  const ledger=mirror.holderFirst;
  if(ledger.version!==1)return {qty:current,reason:`${symbol}: unknown ownership ledger, freeze`};
  const active=contributions.filter(c=>c.qty!==0);
  let rec=ledger.owners[symbol]||null;
  if(!current){
    if(active.length>1)return {qty:0,reason:`${symbol}: both desks want a flat symbol; no netted entry`};
    if(!active.length){delete ledger.challenges[symbol];return {qty:0};}
    const c=active[0];
    if(rec){
      if(c.desk===rec.owner)return {qty:0,reason:`${symbol}: previously held coin closed outside a new authorization`};
      if(!rec.releaseAt || !fresh(c.eventAt) || parsed(c.eventAt)<=parsed(rec.releaseAt) ||
         now-parsed(c.eventAt)>150000)
        return {qty:0,reason:`${symbol}: new challenger signal required AFTER holder RELEASE and Binance flat confirmation`};
      ledger.owners[symbol]={owner:c.desk,contested:false,recordedAt:new Date(now).toISOString()};
      delete ledger.challenges[symbol];
    }
    return {qty:c.qty};
  }
  const direction=sign(current);
  if(!rec){
    const known=originalOwner(state,symbol,direction);
    const matches=active.filter(c=>sign(c.qty)===direction);
    const owner=known || (matches.length===1?matches[0].desk:null);
    if(!owner){
      return {qty:current,reason:`${symbol}: cannot verify incumbent owner, exchange unchanged`};
    }
    const peerActive=active.some(c=>c.desk!==owner);
    rec={owner,contested:peerActive,recordedAt:new Date(now).toISOString()};
    ledger.owners[symbol]=rec;
  }
  const own=contributions.find(c=>c.desk===rec.owner);
  const peers=active.filter(c=>c.desk!==rec.owner);
  if(peers.length){
    const old=ledger.challenges[symbol]||{};
    ledger.challenges[symbol]={
      symbol,holder:rec.owner,challenger:peers[0].desk,
      wantedSide:sign(peers[0].qty)>0?'LONG':'SHORT',
      wantedQty:peers[0].qty,
      requestedAt:old.requestedAt||new Date(now).toISOString(),
      updatedAt:new Date(now).toISOString(),
      holderOptions:'HOLD, REDUCE or CLOSE'
    };
    rec.contested=true;
  }else delete ledger.challenges[symbol];
  if(!rec.contested)return {qty:desired};
  if(own?.qty && sign(own.qty)===direction){
    // Permit holder-initiated reductions. Never re-add quantity merely to undo
    // an earlier unauthorized net-off, or use challenger size to reduce holding.
    const qty=direction*Math.min(Math.abs(current),Math.abs(own.qty));
    return {qty,reason:`${symbol}: ${rec.owner} is holder; peer contribution blocked until holder decision`};
  }
  if(own?.qty && sign(own.qty)!==direction)
    return {qty:current,reason:`${symbol}: owner direction conflicts with Binance, freeze`};
  if(released(state,rec.owner,symbol,ledger.challenges[symbol]?.requestedAt||rec.recordedAt,now)){
    rec.releaseAt ||=new Date(now).toISOString();
    return {qty:0,reason:`${symbol}: ${rec.owner} approved CLOSE; reduce-only flatten, challenger waits for fresh order`};
  }
  return {qty:current,reason:`${symbol}: ${rec.owner} has NOT approved RELEASE, peer blocked`};
}
JS
python3 - "$SRC" "$BACK/research-live.staged.mjs" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text()
assert 'HOLDER_FIRST_V1' not in src
assert src.count('export function planResearchLive(')==1
assert src.count('export function researchLiveContext(')==1
old="  const desired=contributions.reduce((sum,c)=>sum+c.qty,0),target=mirror.blocked[symbol]?0:desired;"
new="""  // HOLDER_FIRST_V1: physical position holder has authority over normal netting.
  const desired=contributions.reduce((sum,c)=>sum+c.qty,0);
  const holderGate=holderFirstTarget(state,mirror,symbol,contributions,current,now);
  const target=mirror.blocked[symbol]?0:holderGate.qty;
  if(holderGate.reason)decision.reasons.push(holderGate.reason);"""
assert src.count(old)==1,'planner changed; no patch'
ctx="  execution:{tradingStatus:state.tradingControl?.status || 'running'"
new_ctx="""  // HOLDER_FIRST_V1: requests appear in the holder's next independent model context.
  holderFirstRequests:Object.values(mirror?.holderFirst?.challenges||{}).filter(r=>r.holder===who),
   holderFirstPolicy:'If another desk challenges a coin you hold, independently evaluate its proposal. HOLD denies it. REDUCE adjusts only your own quantity. CLOSE releases only after Binance verifies flat; emergency exits remain exempt.',
  execution:{tradingStatus:state.tradingControl?.status || 'running'"""
assert src.count(ctx)==1,'research context changed; no patch'
out="import { holderFirstTarget } from './research-holder-first.mjs';\n"+src.replace(old,new,1).replace(ctx,new_ctx,1)
assert out.count('HOLDER_FIRST_V1')==2
assert 'STALE_RESEARCH_REOPEN_GUARD_V1' in out
assert 'researchStopBlocker(state,symbol,{now})' in out
Path(sys.argv[2]).write_text(out)
print('PASS: isolated planner veto and peer challenge prompt context')
PY
docker compose exec -T twin-desk node --check --input-type=module < "$BACK/research-live.staged.mjs"
docker compose exec -T twin-desk node --check --input-type=module < "$BACK/research-holder-first.mjs"
cat > "$BACK/test.mjs" <<'JS'
import assert from 'node:assert/strict';
import {holderFirstTarget as gate} from '/audit/research-holder-first.mjs';
const NOW=Date.parse('2026-11-11T12:22:00.000Z');
const state={
 directBinance:{orders:{a:{symbol:'AGTUSDT',side:'SELL',status:'filled',reduceOnly:false,createdAt:'2026-11-11T11:29:59.212Z',
 researchMirror:{contributions:[{desk:'atlas',qty:0},{desk:'oracle',qty:-42401}]}}}},
 desks:{oracle:{last:{researchAssessments:[]},futuresShadow:{trades:[]}}}
};
const mirror=()=>({version:1,owners:{},challenges:{}});
const rows=(atlas,oracle,time='2026-11-11T12:21:39.059Z')=>[
 {desk:'atlas',qty:atlas,eventAt:time},{desk:'oracle',qty:oracle,eventAt:'2026-11-11T11:29:58.356Z'}];
const m=mirror();
assert.equal(gate(state,m,'AGTUSDT',rows(16984,-42401),-25417,NOW).qty,-25417,'Atlas cannot reduce Oracle');
assert.equal(m.holderFirst.owners.AGTUSDT.owner,'oracle');
assert.equal(m.holderFirst.challenges.AGTUSDT.challenger,'atlas');
assert.equal(gate(state,m,'AGTUSDT',rows(16984,-20000),-25417,NOW).qty,-20000,'Holder reduction approved');
assert.equal(gate(state,m,'AGTUSDT',rows(16984,0),-25417,NOW).qty,-25417,'No implicit release');
state.desks.oracle.last.researchAssessments=[{symbol:'AGTUSDT',action:'close',at:'2026-11-11T12:22:05.000Z'}];
assert.equal(gate(state,m,'AGTUSDT',rows(16984,0),-25417,NOW+10000).qty,0,'Model-authorized close');
assert.equal(gate(state,m,'AGTUSDT',rows(16984,0),0,NOW+10000).qty,0,'Old challenger cannot enter');
assert.equal(gate(state,m,'AGTUSDT',rows(16984,0,'2026-11-11T12:22:15.000Z'),0,NOW+20000).qty,16984,'Fresh handoff');
state.desks.oracle.last.researchAssessments=[];
const partialOwner=mirror();
assert.equal(gate(state,partialOwner,'AGTUSDT',rows(16984,0),-42401,NOW).qty,-42401,'Peer-only claim cannot seize live SHORT');
const noProof={desks:state.desks,directBinance:{orders:{}}};
const noHistory=mirror();
assert.equal(gate(noProof,noHistory,'AGTUSDT',rows(16984,0),-42401,NOW).qty,-42401,'No owner proof freezes opposite entry');
const n=mirror();
assert.equal(gate(state,n,'XYZUSDT',rows(100,0),0,NOW).qty,100,'Unopposed new position');
assert.equal(gate(state,n,'XYZUSDT',rows(100,-100),0,NOW).qty,0,'Flat conflict blocked');
console.log('PASS: eleven holder-first scenarios, AGTUSDT included');
JS
# Self-contained test bundle: feed Node through stdin. No Docker volume mounts.
# A mounted /audit directory is not guaranteed to appear in the target daemon.
python3 - "$BACK/research-holder-first.mjs" "$BACK/test.mjs" "$BACK/test-bundle.mjs" <<'PY'
from pathlib import Path
import sys
mod=Path(sys.argv[1]).read_text()
test=Path(sys.argv[2]).read_text()
assert mod.count('export function holderFirstTarget')==1
anchor="import {holderFirstTarget as gate} from '/audit/research-holder-first.mjs';"
assert test.count(anchor)==1
bundle=mod.replace('export function holderFirstTarget','function holderFirstTarget',1)+"\n"+test.replace(anchor,'const gate=holderFirstTarget;',1)
Path(sys.argv[3]).write_text(bundle)
print('PASS: self-contained test bundle assembled')
PY
OLDIMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
docker run --rm -i --network none --read-only --entrypoint node "$OLDIMAGE" --input-type=module < "$BACK/test-bundle.mjs"
echo "STAGED: $BACK"
echo '=== CHECK IF BINANCE IS SAFE FOR ENGINE RESTART ==='
if ! docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=Date.now()-Date.parse(e.at||'');
const safe=e.connected===true&&e.positionsStale===false&&age>=0&&age<=180000&&
  Array.isArray(e.positions)&&e.positions.length===0&&
  Array.isArray(e.openOrders)&&e.openOrders.length===0&&
  Array.isArray(e.algoOrders)&&e.algoOrders.length===0&&
  !s.pendingOrders?.length&&!s.executionIssue&&
  !Object.values(s.directBinance?.orders||{}).some(o=>['claimed','sending','outcome_unknown'].includes(o.status));
console.log(JSON.stringify({safeToRestart:safe,openSymbols:(e.positions||[]).map(p=>p.symbol),entriesPaused:s.livePaused}));
if(!safe)process.exit(10);
JS
then
  echo 'STAGED ONLY: open or unverified exchange positions. No restart; no code or trading settings changed.'
  echo 'Rerun installer once positions are flat. Software-only protection left running.'
  exit 0
fi
echo '=== PAUSE ENTRIES AND VERIFY EXCHANGE STILL FLAT ==='
ORIGINAL_PAUSED="$(docker compose exec -T twin-desk node -e "const s=require('/app/data/clean-v1-state.json');process.stdout.write(String(s.livePaused===true))")"
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
await setEntriesPaused(true);
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
if(!s.livePaused || !e.connected || e.positionsStale || (e.positions||[]).length ||
(e.openOrders||[]).length || (e.algoOrders||[]).length || s.pendingOrders?.length)
throw Error('ABORT: not paused and flat');
console.log('PASS: entries paused, exchange flat');
JS
OLDTAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
ROLLBACK="twin-desk:rollback-holder-first-$STAMP"
docker image tag "$OLDIMAGE" "$ROLLBACK"
APPLIED=0
RECREATED=0
COMPLETE=0
recover(){
  local rc=$?
  if [ "$COMPLETE" != 1 ]; then
    echo "FAIL ($rc): rollback previous source and image. Trading entries remain PAUSED."
    if [ "$APPLIED" = 1 ]; then cp -a "$BACK/research-live.original.mjs" "$SRC" || true; rm -f "$HELP"; fi
    docker image tag "$ROLLBACK" "$OLDTAG" || true
    if [ "$RECREATED" = 1 ]; then docker compose up -d --no-deps --force-recreate twin-desk || true; fi
    echo "Backup: $BACK"
  fi
}
trap recover EXIT
test "$(sha256sum "$SRC" | awk '{print $1}')" = "$OLD_SHA"
APPLIED=1
cp -a "$BACK/research-live.staged.mjs" "$SRC"
cp -a "$BACK/research-holder-first.mjs" "$HELP"
echo '=== BUILD HOLDER-FIRST IMAGE ==='
docker compose build twin-desk
NEWHASH="$(sha256sum "$SRC" | awk '{print $1}')"
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-live.mjs | awk '{print $1}')" = "$OLD_SHA"
RECREATED=1
docker compose up -d --no-deps --force-recreate twin-desk
NEWCID="$(docker compose ps -q twin-desk)"
test -n "$NEWCID"
for _ in $(seq 1 60); do
  test "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID" 2>/dev/null || true)" = healthy && break
  sleep 5
done
test "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID")" = healthy
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-live.mjs | awk '{print $1}')" = "$NEWHASH"
test "$(docker compose exec -T twin-desk sha256sum /app/vps/lib/research-holder-first.mjs | awk '{print $1}')" = "$(sha256sum "$HELP" | awk '{print $1}')"
echo '=== WAIT FOR FRESH POST-RESTART MARKET, NO OPEN POSITIONS ==='
STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$NEWCID")"
READY=0
for _ in $(seq 1 76); do
  if docker compose exec -T -e ENGINE_STARTED="$STARTED" twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=x=>Date.now()-Date.parse(x||'');
const good=s.livePaused===true&&s.tradingControl?.status==='running'&&
 e.connected===true&&e.positionsStale===false&&
 age(e.at)>=0&&age(e.at)<=180000&&age(s.market?.asOf)>=0&&age(s.market?.asOf)<=300000&&
 Date.parse(s.market?.asOf||'')>=Date.parse(process.env.ENGINE_STARTED||'')&&
 Object.keys(s.market?.symbols||{}).length>0&&
 Array.isArray(e.positions)&&!e.positions.length&&
 Array.isArray(e.openOrders)&&!e.openOrders.length&&
 Array.isArray(e.algoOrders)&&!e.algoOrders.length&&
 !s.pendingOrders?.length&&!s.executionIssue;
console.log(JSON.stringify({ready:good,marketAgeSec:Math.round(age(s.market?.asOf)/1000),exchangeAgeSec:Math.round(age(e.at)/1000)}));
process.exit(good?0:10);
JS
  then READY=1; break; fi
  sleep 15
done
test "$READY" = 1 || { echo 'ABORT: scanner or exchange did not become fresh'; exit 1; }
echo '=== RESTORE ORIGINAL ENTRY PAUSE CHOICE ==='
if [ "$ORIGINAL_PAUSED" = false ]; then
  docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
if(!s.livePaused||!e.connected||e.positionsStale||(e.positions||[]).length||
(e.openOrders||[]).length||(e.algoOrders||[]).length||s.pendingOrders?.length||s.executionIssue)
throw Error('Cannot safely reenable');
await setEntriesPaused(false);
if(JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')).livePaused!==false)throw Error('Not enabled');
console.log('PASS: normal Demo entries enabled, holder-first gate active');
JS
else
  echo 'PASS: entries left paused as they were originally'
fi
COMPLETE=1
trap - EXIT
echo '=== HOLDER-FIRST V1 DEPLOYED ==='
echo "Planner SHA256: $NEWHASH"
echo 'Atlas and Oracle remain independent. Conflicting live-symbol exposure requires holder action.'
echo 'Software protection remains software-only; no exchange-native stop is guaranteed.'
echo "Backup: $BACK"
docker compose ps twin-desk

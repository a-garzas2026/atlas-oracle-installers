#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/twin-desk
umask 077

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$PWD/backups/scanner-top10-$STAMP"
mkdir -p "$BACKUP"
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
IMAGE_TAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
OLD_IMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
ROLLBACK="twin-desk:rollback-scanner-top10-$STAMP"
FILES=(vps/lib/desk-scanner.mjs vps/lib/engine.mjs vps/lib/research-top1-entry.mjs)
for f in "${FILES[@]}"; do cp -a "$f" "$BACKUP/$(basename "$f")"; done
# Preserve previous live fix: never deploy without it.
grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' vps/lib/research-live.mjs
docker image tag "$OLD_IMAGE" "$ROLLBACK"
docker compose exec -T twin-desk cat /app/data/clean-v1-state.json > "$BACKUP/state.json"
test -s "$BACKUP/state.json"
SUCCESS=0; RESTARTED=0
recover(){
  rc=$?
  if [ "$SUCCESS" != 1 ]; then
    echo "UPGRADE ABORTED ($rc): restoring original source and image tag"
    for f in "${FILES[@]}"; do cp -a "$BACKUP/$(basename "$f")" "$f" || true; done
    docker image tag "$ROLLBACK" "$IMAGE_TAG" || true
    if [ "$RESTARTED" = 1 ]; then
      docker compose up -d --no-deps --force-recreate twin-desk || true
    fi
    docker compose ps twin-desk || true
    echo "Backup: $BACKUP"
  fi
}
trap recover EXIT

cat > "$BACKUP/test.mjs" <<'JS'
import fs from 'node:fs';
import {selectDeskSetups} from '/app/vps/lib/desk-scanner.mjs';
import {authorizeResearchTop1,applyFocusedEntry} from '/app/vps/lib/research-top1-entry.mjs';
import {planResearchLive} from '/app/vps/lib/research-live.mjs';
const assert=(test,msg)=>{if(!test)throw new Error('TEST FAILED: '+msg)};
const state=JSON.parse(fs.readFileSync('/audit/state.json','utf8'));
assert(state.exchange?.connected===true && state.exchange?.positionsStale===false,'exchange snapshot not fresh');
const upgraded=fs.readFileSync('/app/vps/lib/desk-scanner.mjs','utf8').includes('SCANNER_TOP10_RESEARCH_V1');
const results={upgraded,desks:{}};
for(const desk of ['atlas','oracle']){
  const ranked=state.market?.deskRankings?.[desk];
  assert(Array.isArray(ranked),'deskRankings missing '+desk);
  const real=ranked.filter(r=>typeof r?.symbol==='string' &&
    ['ready','forming','not_ready'].includes(r.readiness) &&
    Number.isFinite(Number(r.score)));
  assert(new Set(real.map(r=>r.symbol)).size>=10,'fewer than 10 real scored markets for '+desk);
  const prev=state.market?.deskWatchlists?.[desk]||[];
  const picked=selectDeskSetups(ranked,prev,10);
  const bySymbol=new Map(real.map(r=>[r.symbol,r]));
  assert(picked.every(s=>bySymbol.has(s)),'unknown symbol selected '+desk);
  assert(new Set(picked).size===picked.length,'duplicate symbol selected '+desk);
  if(upgraded) assert(picked.length===10,'did not select 10 for '+desk);
  // Existing Gemini TOP-1 semantics are preserved with ten unique ranks.
  if(upgraded){
    const rows=picked.map((symbol,i)=>({symbol,researchRank:i+1,
      action:i===0?'buy':'sell',size:0.15,leverage:10}));
    const auth=authorizeResearchTop1(rows,picked);
    assert(auth.filter(r=>r.action!=='hold').length===1,'multiple Gemini entries '+desk);
    const invalid=authorizeResearchTop1(rows.map(r=>({...r,researchRank:1})),picked);
    assert(invalid.every(r=>r.action==='hold'),'duplicate ranks did not fail closed '+desk);
  }
  results.desks[desk]={pool:real.length,selected:picked.length,
    eligible:picked.filter(s=>['ready','forming'].includes(bySymbol.get(s).readiness)).length,
    researchOnly:picked.filter(s=>bySymbol.get(s).readiness==='not_ready').length,
    symbols:picked};
}
if(upgraded){
  const blocked=applyFocusedEntry([{symbol:'WATCHONLYUSDT',action:'buy',size:0.15,leverage:10}],{
    entryReadiness:{WATCHONLYUSDT:'not_ready'},availableMargin:1000});
  assert(blocked[0].action==='hold' && blocked[0].reviewStatus==='scanner_research_only',
    'research-only candidate was not blocked');
  const underCap=applyFocusedEntry([{symbol:'YBUSDT',action:'buy',size:0.15,leverage:10}],{
    entryReadiness:{YBUSDT:'forming'},availableMargin:1000,marks:{YBUSDT:0.05},
    leverageRules:{at:new Date().toISOString(),bySymbol:{YBUSDT:[{
      notionalFloor:0,notionalCap:5000,maxLeverage:5}]}}});
  assert(underCap[0].action==='hold','YBUSDT 5x bracket could open a 10x trade');
}
// This scanner change must not alter current position reductions or stale-YB guard.
const planning=structuredClone(state);
const at=Date.parse(state.exchange?.at||state.exchange?.asOf||'');
const plan=planResearchLive(planning,{now:Number.isFinite(at)?at:Date.now()});
const yOpens=plan.orders.filter(o=>o.symbol==='YBUSDT'&&!o.reduce);
assert(yOpens.length===0,'stale YBUSDT reopen returned');
results.reductions=plan.orders.filter(o=>o.reduce).map(o=>({symbol:o.symbol,side:o.side,qty:o.qty}))
  .sort((a,b)=>a.symbol.localeCompare(b.symbol)||a.side.localeCompare(b.side));
console.log('SCANNER_PROBE='+JSON.stringify(results));
JS
probe(){
  docker run --rm -i --network none --read-only --user 0 \
    -v "$BACKUP/state.json:/audit/state.json:ro" \
    --entrypoint node "$IMAGE_TAG" --input-type=module < "$BACKUP/test.mjs"
}
echo '=== BASELINE: READ-ONLY SCANNER PROBE ==='
probe > "$BACKUP/before.txt"
if ! grep -q '^SCANNER_PROBE=' "$BACKUP/before.txt"; then
  echo 'BASELINE PROBE DID NOT RETURN DATA:'
  cat "$BACKUP/before.txt"
  exit 1
fi
grep '^SCANNER_PROBE=' "$BACKUP/before.txt" | sed 's/^SCANNER_PROBE=//' | python3 -m json.tool

python3 - <<'PY'
from pathlib import Path

scanner=Path('vps/lib/desk-scanner.mjs')
s=scanner.read_text()
start='export function selectDeskSetups(scored = [], previous = [], limit = 10) {'
end='\nexport const DESK_STRATEGIES'
assert s.count(start)==1 and s.count(end)==1 and 'SCANNER_TOP10_RESEARCH_V1' not in s
before=s.index(start)
after=s.index(end,before)
replacement='''// SCANNER_TOP10_RESEARCH_V1: 10 real ranked research candidates when available.
// Only ready/forming setups are entry-eligible; remaining slots are WATCH ONLY.
export function selectDeskSetups(scored = [], previous = [], limit = 10) {
  const cap=Math.max(0,Math.min(10,Math.floor(Number(limit)||0)));
  const prior=new Set(Array.isArray(previous)?previous:[]);
  const rows=(Array.isArray(scored)?scored:[]).filter(r=>
    typeof r?.symbol==='string' && r.symbol &&
    ['ready','forming','not_ready'].includes(r.readiness) &&
    Number.isFinite(Number(r.score)));
  const eligible=rows.filter(r=>r.readiness==='ready'||r.readiness==='forming')
    .sort((a,b)=>Number(b.readiness==='ready')-Number(a.readiness==='ready') ||
      (Number(b.score)+(prior.has(b.symbol)?2:0))-(Number(a.score)+(prior.has(a.symbol)?2:0)) ||
      a.symbol.localeCompare(b.symbol));
  const watchOnly=rows.filter(r=>r.readiness==='not_ready')
    .sort((a,b)=>Number(b.score)-Number(a.score) ||
      (Number(b.quoteVolume)||0)-(Number(a.quoteVolume)||0) ||
      a.symbol.localeCompare(b.symbol));
  const chosen=[],seen=new Set();
  for(const row of [...eligible,...watchOnly]){
    if(chosen.length>=cap)break;
    if(!seen.has(row.symbol)){seen.add(row.symbol);chosen.push(row.symbol);}
  }
  return chosen;
}
'''
s=s[:before]+replacement+s[after:]
scanner.write_text(s)

focus=Path('vps/lib/research-top1-entry.mjs')
s=focus.read_text()
old='export function applyFocusedEntry(rows,{leverageRules=null,availableMargin=null,marks={},exchangePositions=[]}={}){'
new='export function applyFocusedEntry(rows,{leverageRules=null,availableMargin=null,marks={},exchangePositions=[],entryReadiness={}}={}){'
assert s.count(old)==1 and 'scanner_research_only' not in s
s=s.replace(old,new,1)
old="    if(!row||row.action==='hold')return row;\n    const size=row.size,leverage=row.leverage;"
new="""    if(!row||row.action==='hold')return row;
    // A TOP-10 research slot is NOT an entry authorization.
    if(!['ready','forming'].includes(entryReadiness?.[row.symbol]))
      return {...row,action:'hold',size:0,reviewStatus:'scanner_research_only',
        reviewReason:'Scanner candidate is not READY or FORMING: research only, no opening order.'};
    const size=row.size,leverage=row.leverage;"""
assert s.count(old)==1
focus.write_text(s.replace(old,new,1))

engine=Path('vps/lib/engine.mjs')
s=engine.read_text()
old='  const specialistUniverse=deskUniverse(market.snapshot,who,researchMode,UNIVERSE);'
new=old+"\n  const entryReadiness=Object.fromEntries((market.snapshot?.deskRankings?.[who]||[]).filter(r=>typeof r?.symbol==='string').map(r=>[r.symbol,r.readiness]));"
assert s.count(old)==1 and 'const entryReadiness=Object.fromEntries' not in s
s=s.replace(old,new,1)
old='    entryReviewSymbols: researchMode&&!noEligibleEntry ? [...specialistUniverse] : [],'
new=old+"\n    scannerResearchOnlySymbols:researchMode?specialistUniverse.filter(symbol=>!['ready','forming'].includes(entryReadiness[symbol])):[],"
assert s.count(old)==1
s=s.replace(old,new,1)
old='  if (researchMode && !noEligibleEntry) {\n    body.generationConfig.responseSchema.properties.entryAssessments='
new="""  if (researchMode && !noEligibleEntry) {
    if(top1Mode)body.systemInstruction.parts[0].text += ' SCANNER TOP-10 RESEARCH SLOTS: Rerank all ten real candidates. A symbol in scannerResearchOnlySymbols is NOT READY and must be HOLD for new entries. This additional research coverage never authorizes an entry. Existing positions are assessed separately for HOLD, ADD, REDUCE or CLOSE.';
    body.generationConfig.responseSchema.properties.entryAssessments="""
assert s.count(old)==1
s=s.replace(old,new,1)
old='parsed.entryAssessments=top1Mode ? applyFocusedEntry(unheldRows,{leverageRules:market.leverageRules,availableMargin:self.futuresShadow?.available,marks,exchangePositions:state.exchange?.positions||[]}) : budgetedRows;'
new='parsed.entryAssessments=top1Mode ? applyFocusedEntry(unheldRows,{leverageRules:market.leverageRules,availableMargin:self.futuresShadow?.available,marks,exchangePositions:state.exchange?.positions||[],entryReadiness}) : budgetedRows;'
assert s.count(old)==1
engine.write_text(s.replace(old,new,1))
print('PASS: TOP-10 scanner, research-only gate, and Gemini guidance patched')
PY

echo '=== BUILD (RUNNING CONTAINER UNTOUCHED) ==='
docker compose build twin-desk
for f in desk-scanner engine research-top1-entry research-live; do
  docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" \
    --check "/app/vps/lib/$f.mjs"
done

echo '=== BEFORE/AFTER TEST USING THE SAME REAL MARKET SNAPSHOT ==='
probe > "$BACKUP/after.txt"
python3 - "$BACKUP/before.txt" "$BACKUP/after.txt" <<'PY'
import json,sys

def load(path):
    r=[json.loads(line.removeprefix('SCANNER_PROBE=')) for line in open(path) if line.startswith('SCANNER_PROBE=')]
    assert len(r)==1, 'One test result required'
    return r[0]

before,after=map(load,sys.argv[1:])
assert before['upgraded'] is False and after['upgraded'] is True
for desk in ('atlas','oracle'):
    old,new=before['desks'][desk],after['desks'][desk]
    assert new['selected']==10, f'{desk} shortlist not ten'
    assert set(old['symbols']).issubset(new['symbols']), f'{desk} old candidates lost'
    assert new['eligible']+new['researchOnly']==10
    print(f"PASS {desk.upper()}: {old['selected']} -> 10 genuine candidates; {new['eligible']} eligible, {new['researchOnly']} watch-only")
assert before['reductions']==after['reductions'], 'Position reduction plans changed'
print('PASS: existing reduction plans unchanged')
print('PASS: TOP-1 fail-closed, watch-only BUY veto, 5x YBUSDT rejection tested')
PY

echo '=== CONTROLLED DEPLOYMENT ==='
RESTARTED=1
docker compose up -d --no-deps --force-recreate twin-desk
HEALTH=starting
for i in $(seq 1 45); do
  CID="$(docker compose ps -q twin-desk)"
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID")"
  if [ "$HEALTH" = healthy ]; then break; fi
  if [ "$HEALTH" = unhealthy ] || [ "$HEALTH" = exited ]; then break; fi
  sleep 2
done
test "$HEALTH" = healthy
docker compose exec -T twin-desk grep -q 'SCANNER_TOP10_RESEARCH_V1' /app/vps/lib/desk-scanner.mjs
docker compose exec -T twin-desk grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' /app/vps/lib/research-live.mjs
SUCCESS=1
trap - EXIT
echo 'SUCCESS: TOP-10 SCANNER DEPLOYED; live Gemini-cycle validation still required'
echo "Backup: $BACKUP"
echo "Rollback image: $ROLLBACK"
docker compose ps twin-desk
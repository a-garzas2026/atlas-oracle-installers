#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/twin-desk
umask 077

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$PWD/backups/best-eligible-profit-$STAMP"
mkdir -p "$BACKUP"
CID="$(docker compose ps -q twin-desk)"
test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
IMAGE_TAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
OLD_IMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
ROLLBACK="twin-desk:rollback-best-eligible-$STAMP"
FILES=(vps/lib/engine.mjs vps/lib/research-top1-entry.mjs)
for f in "${FILES[@]}"; do cp -a "$f" "$BACKUP/$(basename "$f")"; done
# The working TOP-10 scanner and YBUSDT reconciliation fix are prerequisites.
grep -q 'SCANNER_TOP10_RESEARCH_V1' vps/lib/desk-scanner.mjs
grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' vps/lib/research-live.mjs
docker image tag "$OLD_IMAGE" "$ROLLBACK"
docker compose exec -T twin-desk cat /app/data/clean-v1-state.json > "$BACKUP/state.json"
test -s "$BACKUP/state.json"
SUCCESS=0
RESTARTED=0
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

cat > "$BACKUP/probe.mjs" <<'JS'
import fs from 'node:fs';
import {planResearchLive} from '/app/vps/lib/research-live.mjs';
const state=JSON.parse(fs.readFileSync('/audit/state.json','utf8'));
if(state.exchange?.connected!==true || state.exchange?.positionsStale!==false)
  throw Error('Read-only exchange snapshot not connected or marked stale; abort deployment');
const planner=structuredClone(state);
const stamp=Date.parse(state.exchange?.at||state.exchange?.asOf||'');
const plan=planResearchLive(planner,{now:Number.isFinite(stamp)?stamp:Date.now()});
const reductions=plan.orders.filter(x=>x.reduce).map(x=>({
  symbol:x.symbol,side:x.side,qty:x.qty
})).sort((a,b)=>a.symbol.localeCompare(b.symbol)||a.side.localeCompare(b.side));
const ybusdtOpen=plan.orders.some(x=>x.symbol==='YBUSDT'&&!x.reduce);
const modified=fs.readFileSync('/app/vps/lib/research-top1-entry.mjs','utf8').includes('BEST_ELIGIBLE_EXPECTED_PROFIT_V1');
const result={modified,reductions,ybusdtOpen};
if(modified){
  const {authorizeResearchTop1,authorizeResearchBestEligible,applyFocusedEntry}=await import('/app/vps/lib/research-top1-entry.mjs');
  const assert=(ok,m)=>{if(!ok)throw Error('BEST ELIGIBLE SAFETY TEST FAILED: '+m)};
  const symbols=['YBUSDT','QUSDT','RUSDT','WATCHUSDT','C4USDT','C5USDT','C6USDT','C7USDT','C8USDT','C9USDT'];
  const makeRows=()=>symbols.map((symbol,i)=>({symbol,researchRank:i+1,
    action:i<3?'buy':'hold',size:i<3?0.15:0,leverage:10}));
  const rule=maxLeverage=>[{notionalFloor:0,notionalCap:5000,maxLeverage}];
  const leverageRules={at:new Date().toISOString(),bySymbol:{
    YBUSDT:rule(5),QUSDT:rule(20),RUSDT:rule(20)
  }};
  const context={leverageRules,availableMargin:1000,
    marks:{YBUSDT:1,QUSDT:1,RUSDT:1},exchangePositions:[],
    entryReadiness:{YBUSDT:'forming',QUSDT:'ready',RUSDT:'forming',WATCHUSDT:'not_ready'}};
  const approve=rows=>authorizeResearchBestEligible(applyFocusedEntry(rows,context),symbols);
  const openings=rows=>rows.filter(x=>x.action==='buy'||x.action==='sell');
  const selected=approve(makeRows());
  assert(openings(selected).length===1,'more than one entry');
  assert(openings(selected)[0].symbol==='QUSDT','did not choose rank 2 after rank 1 leverage denial');
  assert(selected.find(x=>x.symbol==='YBUSDT').action==='hold','5x YBUSDT could be traded at 10x');
  assert(selected.find(x=>x.symbol==='RUSDT').action==='hold','lower eligible rank also authorized');
  const rank1Hold=makeRows();rank1Hold[0].action='hold';rank1Hold[0].size=0;
  assert(openings(approve(rank1Hold))[0]?.symbol==='QUSDT','no fallthrough after research HOLD');
  const rank1Ready=makeRows();rank1Ready[0].symbol='QUSDT';rank1Ready[1].symbol='YBUSDT';
  const selectedRank1=approve(rank1Ready);
  assert(openings(selectedRank1).length===1&&openings(selectedRank1)[0].researchRank===1,
    'highest eligible rank not chosen');
  const duplicateRanks=makeRows();duplicateRanks[1].researchRank=1;
  assert(openings(approve(duplicateRanks)).length===0,'duplicate rank did not fail closed');
  const unknown=makeRows();unknown[0].symbol='UNKNOWNUSDT';
  assert(openings(approve(unknown)).length===0,'unknown symbol did not fail closed');
  const owned=makeRows();owned[1].action='hold';owned[1].size=0;
  assert(openings(approve(owned))[0]?.symbol==='RUSDT','owned/HOLD rank 2 did not skip to rank 3');
  const watch=makeRows();watch[0].action='hold';watch[0].size=0;
  watch[1].action='hold';watch[1].size=0;
  watch[2].action='hold';watch[2].size=0;
  watch[3].action='buy';watch[3].size=0.15;
  assert(openings(approve(watch)).length===0,'research-only WATCH candidate could open');
  assert(openings(authorizeResearchTop1(makeRows(),symbols)).length===1,
    'legacy TOP-1 gate changed');
  const engine=fs.readFileSync('/app/vps/lib/engine.mjs','utf8');
  assert(engine.includes('BEST_ELIGIBLE_EXPECTED_PROFIT_V1'),'engine lacks new selection marker');
  assert(engine.includes('authorizeResearchBestEligible(applyFocusedEntry('),'engine does not enforce final single selection');
  assert(!engine.includes('Every other candidate MUST return HOLD, size 0.'),'main Gemini instructions still require rank-1 only');
  assert(!engine.includes('Only rank 1 may BUY or SELL.'),'fallback Gemini instructions still require rank-1 only');
  assert(!engine.includes('Other ranks HOLD size 0.'),'fallback Gemini instructions still require lower ranks to HOLD');
  result.passedTests=['rank2_fallback','rank1_priority','hold_fallback','owned_skip',
    'duplicate_rank_fail_closed','unknown_symbol_fail_closed','research_only_veto',
    'ybusdt_5x_veto','max_one_new_entry','legacy_gate_unchanged','gemini_prompt_consistency'];
}
console.log('BEST_ELIGIBLE_PROBE='+JSON.stringify(result));
JS
probe(){
  docker run --rm -i --network none --read-only --user 0 \
    -v "$BACKUP/state.json:/audit/state.json:ro" \
    --entrypoint node "$IMAGE_TAG" --input-type=module < "$BACKUP/probe.mjs"
}

echo '=== BASELINE: ISOLATED READ-ONLY POSITION PLAN ==='
probe > "$BACKUP/before.txt"
if ! grep -q '^BEST_ELIGIBLE_PROBE=' "$BACKUP/before.txt"; then
  cat "$BACKUP/before.txt";exit 1
fi
python3 - "$BACKUP/before.txt" <<'PY'
import json,sys
rows=[json.loads(x.removeprefix('BEST_ELIGIBLE_PROBE=')) for x in open(sys.argv[1]) if x.startswith('BEST_ELIGIBLE_PROBE=')]
assert len(rows)==1 and rows[0]['modified'] is False,'Unexpected pre-existing upgrade'
assert not rows[0]['ybusdtOpen'],'Stale YBUSDT opening detected before patch; abort'
print('PASS: original planner snapshot obtained, YBUSDT not reopened')
PY

echo '=== PATCH BEST ELIGIBLE EXPECTED PROFIT SELECTION ==='
python3 - <<'PY'
from pathlib import Path

focus=Path('vps/lib/research-top1-entry.mjs')
s=focus.read_text()
assert 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' not in s
anchor='function suppress(rows,reason){'
assert s.count(anchor)==1
addition='''// BEST_ELIGIBLE_EXPECTED_PROFIT_V1
// Call only AFTER model review, owned-position removal, market readiness and
// account-specific signed Binance notional-bracket leverage checks.
// Research rank orders estimated net-profit opportunities; the first eligible
// actionable proposal is the ONE new entry permitted for this desk/cycle.
export function authorizeResearchBestEligible(rows,symbols){
  if(!Array.isArray(rows)||!Array.isArray(symbols)||rows.length!==symbols.length||
     symbols.length===0||new Set(symbols).size!==symbols.length)
    return suppress(rows,'ranking_unavailable');
  const known=new Set(symbols),seen=new Set(),ranks=new Set();
  for(const row of rows){
    if(!row||!known.has(row.symbol)||seen.has(row.symbol)||
       !Number.isInteger(row.researchRank)||row.researchRank<1||
       row.researchRank>symbols.length||ranks.has(row.researchRank))
      return suppress(rows,'invalid_research_ranking');
    seen.add(row.symbol);ranks.add(row.researchRank);
  }
  if(ranks.size!==symbols.length||!ranks.has(1))
    return suppress(rows,'invalid_research_ranking');
  const eligible=rows.filter(row=>
    (row.action==='buy'||row.action==='sell') &&
    typeof row.size==='number'&&Number.isFinite(row.size)&&row.size>0 &&
    Number.isInteger(row.leverage)&&row.leverage>=ENTRY_LEVERAGE_MIN
  ).sort((a,b)=>a.researchRank-b.researchRank);
  const best=eligible[0]||null;
  return rows.map(row=>{
    if(best && row.symbol===best.symbol)
      return {...row,bestEligibleSelected:true,top1Selected:true,
        top1Status:row.researchRank===1?'rank_1_authorized':
          `rank_${row.researchRank}_best_eligible_authorized`};
    if(row.action==='buy'||row.action==='sell')
      return {...row,action:'hold',size:0,bestEligibleSelected:false,
        top1Selected:false,top1Status:'lower_expected_profit_rank_not_selected',
        reviewReason:'Only the highest-ranked eligible positive-profit new entry may execute this cycle.'};
    return {...row,bestEligibleSelected:false,top1Selected:false,
      top1Status:row.reviewStatus||'not_actionable'};
  });
}

'''
focus.write_text(s.replace(anchor,addition+anchor,1))

engine=Path('vps/lib/engine.mjs')
s=engine.read_text()
assert 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' not in s

changes=[
 ('import { authorizeResearchTop1, applyFocusedEntry, applyDeskEntryBudget } from "./research-top1-entry.mjs";',
  'import { authorizeResearchTop1, authorizeResearchBestEligible, applyFocusedEntry, applyDeskEntryBudget } from "./research-top1-entry.mjs";'),
 ('const rankedRows=expectedProfitRank ? authorizeResearchTop1(reviewed.rows,specialistUniverse) : reviewed.rows;',
  'const rankedRows=expectedProfitRank && !top1Mode ? authorizeResearchTop1(reviewed.rows,specialistUniverse) : reviewed.rows;'),
 ('parsed.entryAssessments=top1Mode ? applyFocusedEntry(unheldRows,{leverageRules:market.leverageRules,availableMargin:self.futuresShadow?.available,marks,exchangePositions:state.exchange?.positions||[],entryReadiness}) : budgetedRows;',
  '// BEST_ELIGIBLE_EXPECTED_PROFIT_V1: approve each prospect, then authorize just the best eligible rank.\n        parsed.entryAssessments=top1Mode ? authorizeResearchBestEligible(applyFocusedEntry(unheldRows,{leverageRules:market.leverageRules,availableMargin:self.futuresShadow?.available,marks,exchangePositions:state.exchange?.positions||[],entryReadiness}),specialistUniverse) : budgetedRows;'),
 ('NEW-ENTRY RERANK: Rank every eligible unheld candidate. Rank 1 may BUY, SELL, or HOLD.',
  'NEW-ENTRY EXPECTED NET PROFIT RERANK: Rank all ten candidates by credible risk-adjusted expected NET profit after fees, slippage and realistic downside over a comparable horizon. Any rank may propose BUY, SELL, or HOLD as an entry intent; the engine authorizes only the highest-ranked eligible proposal.'),
 ('Give EACH candidate a unique integer researchRank 1..N (1 = your strongest opportunity; scanner rank is not authoritative).',
  'Give EACH candidate a unique integer researchRank 1..N (1 = highest credible risk-adjusted expected NET profit after trading costs on comparable margin and horizon; scanner rank is not authoritative). Do not invent probability, expected profit, or order-book evidence.'),
 ('Your OWN researchRank=1 may BUY, SELL, or HOLD.',
  'ANY rank may propose BUY, SELL, or HOLD when independently justified; proposals are not orders. The engine chooses the highest-ranked executable eligible action, at most one new opening per desk cycle.'),
 ('Every other candidate MUST return HOLD, size 0.',
  'Lower ranks MAY propose independently justified BUY or SELL intents with valid prices, size and leverage; otherwise HOLD with size 0. Only the best eligible intent can become an opening order.'),
 ('An open position does not block a new rank-1 long or short.',
  'Existing desk-owned positions are managed through assessments only, never opened or added through entryAssessments.'),
 ('If this desk book is losing or is all one direction, rank 1 may hedge',
  'If this desk book is losing or is all one direction, the highest-ranked eligible trade may hedge'),
 ('Rank the best unheld eligible candidate #1 whenever any unheld candidate exists;',
  'Rank by realistic risk-adjusted expected net profit and do not force a direction merely to fill rank 1;'),
 ('RESEARCH TOP-1 REQUIREMENT: Independently rerank every entryReviewSymbols candidate.',
  'RESEARCH BEST-ELIGIBLE PROFIT REQUIREMENT: Independently rerank every entryReviewSymbols candidate by credible net profit after fees, slippage and downside.'),
 ('Only rank 1 may BUY or SELL. Rank 1 may also HOLD.',
  'Any rank may propose BUY, SELL or HOLD when evidence supports it; only one highest-ranked independently validated eligible action may execute.'),
 ('Other ranks HOLD size 0.',
  'Other ranks may propose BUY or SELL with valid entry evidence, or HOLD with size 0; a research-only scanner candidate always HOLDs.'),
]
for old,new in changes:
 count=s.count(old)
 assert count>=1 and count<=3,(f'Unexpected source contract for {old[:65]}: {count}')
 s=s.replace(old,new)

# Replace the TOP-1 note shown to Gemini in the structured brief, without
# changing the scanner-auto or reference-only note.
import re
patt=r"(scannerEntryNote:\s*noEligibleEntry\s*\?\s*'[^']*'\s*:\s*top1Mode\s*\?\s*)'[^']*'"
replacement=("\\g<1>'Atlas and Oracle independently rerank their own TOP 10 "
  "by credible expected net profit. Every candidate may return a justified "
  "BUY, SELL or HOLD intent. Only the single best eligible actionable rank per "
  "desk can execute; research-only scanner candidates must HOLD. Owned positions "
  "are managed separately.'")
s,count=re.subn(patt,replacement,s)
assert count==1,'Scanner top1 note not uniquely located'
engine.write_text(s)
print('PASS: independent expected-profit rerank, fallback prompt and single-entry final gate patched')
PY

echo '=== BUILD WITHOUT STOPPING THE RUNNING TRADING CONTAINER ==='
docker compose build twin-desk
for f in engine research-top1-entry research-live desk-scanner; do
  docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" \
    --check "/app/vps/lib/$f.mjs"
done

echo '=== COMPARE OLD VS NEW USING SAME SAVED LIVE STATE ==='
probe > "$BACKUP/after.txt"
python3 - "$BACKUP/before.txt" "$BACKUP/after.txt" <<'PY'
import json,sys

def load(file):
    rows=[json.loads(x.removeprefix('BEST_ELIGIBLE_PROBE=')) for x in open(file) if x.startswith('BEST_ELIGIBLE_PROBE=')]
    assert len(rows)==1,'Expected exactly one planner test result'
    return rows[0]

before,after=map(load,sys.argv[1:])
assert before['modified'] is False and after['modified'] is True
assert before['reductions']==after['reductions'],'Existing reduce-only orders changed'
assert not after['ybusdtOpen'],'Stale YBUSDT reopening detected'
assert len(after['passedTests'])>=11,'Required safety tests not completed'
for name in after['passedTests']: print('PASS:',name)
print('PASS: actual current position reduction plan unchanged')
print('PASS: YBUSDT stale-position protection retained')
PY

echo '=== PRE-DEPLOY OPEN ORDER CHECK ==='
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const uncertain=Object.values(s.directBinance?.orders||{}).filter(o=>
  ['claimed','sending','outcome_unknown'].includes(o.status));
if(uncertain.length)throw Error('Unresolved direct orders exist: deployment halted without restarting');
console.log('PASS: no unresolved direct order claims/sends in saved state');
JS

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
docker compose exec -T twin-desk grep -q 'BEST_ELIGIBLE_EXPECTED_PROFIT_V1' /app/vps/lib/research-top1-entry.mjs
docker compose exec -T twin-desk grep -q 'SCANNER_TOP10_RESEARCH_V1' /app/vps/lib/desk-scanner.mjs
docker compose exec -T twin-desk grep -q 'STALE_RESEARCH_REOPEN_GUARD_V1' /app/vps/lib/research-live.mjs
SUCCESS=1
trap - EXIT
echo 'SUCCESS: BEST-ELIGIBLE EXPECTED-PROFIT ENTRY POLICY DEPLOYED; LIVE GEMINI CYCLE NOT YET VERIFIED'
echo "Backup: $BACKUP"
echo "Rollback image: $ROLLBACK"
docker compose ps twin-desk

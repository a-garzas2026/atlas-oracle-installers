// ATLAS_ORACLE_SHADOW_ALTERNATIVE_V1
// Separate, non-executable read-only research process. NO trading imports,
// NO state writes, NO exchange order calls. Two independent Gemini requests.
import fs from 'node:fs';

const state=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));
const market=state.market||{};
const asOf=Date.parse(market.rankingAsOf||'');
const now=Date.now();
const fail=(message)=>{throw new Error('SHADOW ABORT: '+message)};
const finite=x=>typeof x==='number'&&Number.isFinite(x)?x:null;
const positive=x=>finite(x)!==null&&x>0?x:null;
const cleanObj=(input,keys)=>Object.fromEntries(keys.map(k=>[k,input?.[k]??null]));
const isOpen=a=>['buy','sell'].includes(String(a||'').toLowerCase());
const ids=['atlas','oracle'];
if(state.exchange?.connected!==true||state.exchange?.positionsStale!==false)
  fail('saved exchange account data unavailable or stale');
if(!Number.isFinite(asOf)||asOf>now+30000||now-asOf>15*60000)
  fail('scanner ranking is not fresh enough for a shadow comparison');
if(process.env.SCANNER_AUTO_ENTRY_ENABLED==='true')
  fail('unexpected scanner auto-entry flag; inspect trading configuration first');
const context=Object.fromEntries(ids.map(id=>{
  const selected=market.deskWatchlists?.[id]||[];
  const ranking=market.deskRankings?.[id]||[];
  const bySymbol=new Map(ranking.map(r=>[r.symbol,r]));
  const reviews=state.desks?.[id]?.last?.entryAssessments||[];
  const byReview=new Map(reviews.map(r=>[r.symbol,r]));
  if(selected.length!==10||new Set(selected).size!==10)
    fail(id+' scanner must contain ten distinct symbols');
  const models=state.desks?.[id]?.last||{};
  if(!/^gemini-[a-zA-Z0-9._-]+$/.test(models.model||''))
    fail(id+' must have a known previous Gemini model identifier');
  const owned=new Set((state.desks?.[id]?.futuresShadow?.positions||[]).filter(p=>Number(p.qty??p.amt)!==0).map(p=>p.symbol));
  return [id,{
    selected,
    model:models.model,
    lastDecisionAt:models.at,
    availableMargin:finite(state.desks?.[id]?.futuresShadow?.available),
    ownedSymbols:[...owned],
    candidates:selected.map(symbol=>{
      const r=bySymbol.get(symbol)||{};
      const m=market.symbols?.[symbol]||{};
      const prior=byReview.get(symbol)||{};
      const price=positive(m.last)||positive(market.marks?.[symbol]);
      return {symbol,price,atrPct:positive(m.atrPct),readiness:r.readiness||null,
        scannerRank:r.rank??null,scannerScore:r.score??null,
        scannerBias:r.bias??null,
        netRewardRiskProxy:r.netRewardRiskProxy??null,
        costBps:r.costBps??null,roomBps:r.roomBps??null,
        readinessGaps:r.readinessGaps||[],
        liveGeminiAction:prior.modelAction??prior.action??null,
        currentDeskPosition:owned.has(symbol),
        ret15:finite(m.ret15),ret1:finite(m.ret1),ret4:finite(m.ret4),
        ret24:finite(m.ret24),volRatio:finite(m.volRatio),
        takerBuySell:finite(m.takerBuySell),
        shock:m.shock===true,
        levels:cleanObj(m.levels||{},[
          'support','resistance','sessionLow','sessionHigh',
          'previousDayHigh','previousDayLow','vwap24h'
        ])};
    })
  }];
}));

// Avoid printing or persisting keys. Prefer desk-scoped keys; generic fallback
// is allowed only when a clearly-named Gemini key exists.
function findKey(id){
  const vars=Object.entries(process.env);
  const names=vars.filter(([name,val])=>
    /(GEMINI|GOOGLE|ATLAS|ORACLE)/i.test(name)&&/(KEY|TOKEN)/i.test(name)&&
    typeof val==='string'&&val.trim());
  const priority=names.sort(([a],[b])=>{
    const rank=x=>new RegExp(id,'i').test(x)?0:/GEMINI|GOOGLE/i.test(x)?1:9;
    return rank(a)-rank(b);
  });
  for(const [name,value] of priority){
    const isDesk=new RegExp(id,'i').test(name);
    const isGeneric=/GEMINI|GOOGLE/i.test(name)&&!/ATLAS|ORACLE/i.test(name);
    if(!isDesk&&!isGeneric)continue;
    for(const key of value.split(/[\s,;|]+/)){
      if(/^AIza[\w-]{20,}$/.test(key))return key;
    }
  }
  return null;
}

const instruction={
  atlas:'Independent momentum trader. Assess relative-strength continuation and early trend transitions, BOTH LONG and SHORT. Confirm direction, volume, flow and invalidation rather than requiring scanner readiness alone.',
  oracle:'Independent mean-reversion trader. Assess failed breakouts, excess extension, reversal triggers and plausible return toward fair value, BOTH LONG and SHORT. Consider existing portfolio concentration.'
};
const hardGaps=new Set(['price_or_atr_unknown','price_shock','spread_too_wide','spread_unverified']);
const report={version:'ATLAS_ORACLE_SHADOW_ALTERNATIVE_V1',mode:'SHADOW_ONLY_NO_ORDERS',
  generatedAt:new Date().toISOString(),scannerAsOf:market.rankingAsOf,
  exchangeSnapshotConnected:state.exchange.connected,
  policy:'Preserve production readiness veto. No model shadow plan can authorize an order.',desks:{}};

async function assess(id){
  const c=context[id];
  const key=findKey(id);
  if(!key)return {status:'no_desk_gemini_key_found',model:c.model,
    candidates:c.selected.length,ordersSubmitted:0};
  const prompt=`You are ${id.toUpperCase()} performing a SEPARATE SHADOW ANALYSIS, not executing trades. ${instruction[id]}
Do not copy the normal live instruction that scanner not_ready must HOLD. Determine if any NOT_READY candidate could justify an independently validated LONG or SHORT with a better entry/stop/target, while respecting hard market-data problems. Be skeptical of model estimates. NEVER fabricate prices or probability data. Only use the supplied snapshot; missing evidence => HOLD. Existing positions are managed separately and cannot be new entries. A 10x or higher trade would ultimately need FRESH account-specific Binance leverage verification; you cannot perform it. Provide all ten symbols exactly once with independent research ranks 1..10 and a clear rationale even for HOLD. Do not aim for any minimum number of trades. Respond ONLY valid JSON: {"assessments":[{"symbol":"...","researchRank":1,"action":"hold|buy|sell","confidence":0.5,"entry":null,"stop":null,"target":null,"estimatedWinProbability":null,"rationale":"...","missingEvidence":"..."}]}. For BUY/SELL, entry,stop,target MUST be numeric and estimatedWinProbability must be null if not independently supportable. Estimates are proposals, not facts. Expected net profit must include adverse outcomes and trading costs.
MARKET_AND_ACCOUNT_DATA=${JSON.stringify({strategy:id,scannerAsOf:market.rankingAsOf,availableMargin:c.availableMargin,heldPositions:c.ownedSymbols,candidates:c.candidates})}`;
  let resp;
  try{
    resp=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(c.model)}:generateContent`,{
      method:'POST',headers:{'content-type':'application/json','x-goog-api-key':key},
      signal:AbortSignal.timeout(75000),
      body:JSON.stringify({contents:[{role:'user',parts:[{text:prompt}]}],generationConfig:{responseMimeType:'application/json',temperature:0.2}})
    });
    const payload=await resp.json();
    if(!resp.ok)return {status:'gemini_api_error',model:c.model,
      httpCode:resp.status,code:payload?.error?.status||null,
      ordersSubmitted:0};
    const raw=(payload.candidates?.[0]?.content?.parts||[]).map(p=>p.text||'').join('');
    const decoded=JSON.parse(raw);
    if(!Array.isArray(decoded.assessments)||decoded.assessments.length!==10)
      return {status:'invalid_model_response_count',model:c.model,ordersSubmitted:0};
    const seen=new Set(),ranks=new Set();
    for(const r of decoded.assessments){
      if(!r||!c.selected.includes(r.symbol)||seen.has(r.symbol)||
        !Number.isInteger(r.researchRank)||r.researchRank<1||r.researchRank>10||ranks.has(r.researchRank))
        return {status:'invalid_model_response_ranking',model:c.model,ordersSubmitted:0};
      seen.add(r.symbol);ranks.add(r.researchRank);
    }
    const input=new Map(c.candidates.map(x=>[x.symbol,x]));
    const evaluations=decoded.assessments.map(r=>{
      const a=input.get(r.symbol);
      const action=String(r.action||'hold').toLowerCase();
      const problems=[];
      const proposed=isOpen(action);
      if(!['buy','sell','hold'].includes(action))problems.push('unrecognized_action');
      if(a.currentDeskPosition)problems.push('already_owned_by_this_desk');
      if(a.shock||a.readinessGaps.some(g=>hardGaps.has(g)))problems.push('hard_market_data_or_spread_veto');
      const entry=positive(r.entry),stop=positive(r.stop),target=positive(r.target),marketPrice=positive(a.price);
      if(!marketPrice||!positive(a.atrPct))problems.push('missing_price_or_atr');
      if(proposed&&(!entry||!stop||!target))problems.push('incomplete_entry_stop_target');
      if(proposed&&entry&&stop&&target){
        if(action==='buy'&&!(stop<entry&&entry<target))problems.push('invalid_long_stop_target');
        if(action==='sell'&&!(target<entry&&entry<stop))problems.push('invalid_short_stop_target');
        if(marketPrice&&Math.abs(entry/marketPrice-1)>Math.max(0.015,1.5*a.atrPct))
          problems.push('entry_far_from_fresh_reference_price');
      }
      let grossRewardBps=null,lossBps=null,rrAfterCosts=null,expectedNetBps=null;
      if(proposed&&entry&&stop&&target){
        grossRewardBps=1e4*Math.abs(target-entry)/entry;
        lossBps=1e4*Math.abs(entry-stop)/entry;
        const costs=positive(a.costBps);
        if(!costs)problems.push('missing_estimated_round_trip_costs');
        else{
          rrAfterCosts=(grossRewardBps-costs)/(lossBps+costs);
          const p=finite(r.estimatedWinProbability);
          if(p!==null&&p>0&&p<1)expectedNetBps=p*grossRewardBps-(1-p)*lossBps-costs;
          else problems.push('uncalibrated_win_probability_cannot_verify_expectancy');
          if(rrAfterCosts<1.2)problems.push('weak_plan_reward_risk_after_costs');
          if(grossRewardBps<=costs)problems.push('target_does_not_cover_known_costs');
          if(expectedNetBps!==null&&expectedNetBps<=0)problems.push('estimated_nonpositive_expectancy');
        }
        if(lossBps<25||lossBps>500)problems.push('stop_distance_outside_shadow_risk_window');
      }
      if(!proposed)problems.push('gemini_shadow_hold');
      return {researchRank:r.researchRank,symbol:r.symbol,scannerReadiness:a.readiness,
        scannerNetRR:a.netRewardRiskProxy,
        originalLiveGeminiAction:a.liveGeminiAction||null,
        shadowGeminiAction:action,
        confidence:finite(r.confidence),entry,stop,target,
        estimatedWinProbability:finite(r.estimatedWinProbability),
        grossRewardBps,lossBps,netRewardRiskAfterKnownCosts:rrAfterCosts,
        modelEstimatedNetBps:expectedNetBps,
        shadowEvidencePass:proposed&&problems.length===0,
        limits:'NOT EXECUTABLE: probability uncalibrated; signed Binance notional brackets and funding unverified',
        problems,rationale:String(r.rationale||'').slice(0,250),
        missingEvidence:String(r.missingEvidence||'').slice(0,250)};
    }).sort((a,b)=>a.researchRank-b.researchRank);
    return {status:'shadow_assessed',model:c.model,decisionComparedAt:c.lastDecisionAt,
      candidates:evaluations.length,hypotheticalProposals:evaluations.filter(r=>isOpen(r.shadowGeminiAction)).length,
      passedPreliminaryMarketDataChecks:evaluations.filter(r=>r.shadowEvidencePass).length,
      actionableOrders:0,ordersSubmitted:0,
      note:'Probability, funding, fresh signed leverage and account execution are NOT validated.',
      evaluations};
  }catch(e){return {status:'shadow_model_error',model:c.model,
    reason:String(e?.message||e).slice(0,180),ordersSubmitted:0};}
}

// Independent prompts, independently requested, no peer requirement.
const results=await Promise.all(ids.map(async id=>[id,await assess(id)]));
for(const [id,r] of results)report.desks[id]=r;
console.log(JSON.stringify(report,null,2));
if(results.every(([,r])=>r.status==='no_desk_gemini_key_found'))
  process.exitCode=3;

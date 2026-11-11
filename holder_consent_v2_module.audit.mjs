// HOLDER_CONSENT_V2 — explicit independent Gemini-to-Gemini ownership consent.
// Canonical writes occur only under Clerk's existing state lock. No exchange API calls.
import crypto from 'node:crypto';

const SIGN=Math.sign;
const finite=n=>typeof n==='number'&&Number.isFinite(n);
const date=t=>Date.parse(t||'');
const stamp=now=>new Date(now).toISOString();
const less=(a,b)=>Math.abs(a-b)<=Math.max(1e-8,Math.abs(a)*1e-9);
const DESKS=['atlas','oracle'];
const MAX_REQUEST_MS=1_200_000;
const MAX_REPLY_MS=180_000;
const MAX_ENTRY_MS=150_000;
function asNumber(v){const n=Number(v);return Number.isFinite(n)?n:NaN;}
function normAction(v){return String(v||'').trim().toUpperCase();}
function rawBook(state,id,symbol){return state.desks?.[id]?.futuresShadow?.positions?.find(p=>p.symbol===symbol)||null;}
function initLedger(mirror){
  mirror.holderConsentV2 ||= {version:2,owners:{},requests:{},decisions:{},suppressed:{},events:[]};
  const l=mirror.holderConsentV2;
  l.suppressed ||= {};
  if(l.version!==2 || !l.owners || !l.requests || !l.decisions || !l.suppressed || !Array.isArray(l.events))return null;
  return l;
}
function ownerFromConfirmedEntry(state,symbol,direction){
  const claims=Object.values(state.directBinance?.orders||{}).filter(o=>
    o?.symbol===symbol && ['filled','partial'].includes(o.status) && !o.reduceOnly &&
    o.researchMirror?.contributions?.length && Number.isFinite(date(o.createdAt)) &&
    SIGN(o.side==='BUY'?1:-1)===direction
  ).sort((a,b)=>date(b.createdAt)-date(a.createdAt));
  for(const c of claims){
    const matching=c.researchMirror.contributions.filter(x=>
      DESKS.includes(x.desk) && finite(x.qty) && SIGN(x.qty)===direction && x.qty!==0);
    if(matching.length===1)return matching[0].desk;
    // A combined fill is not proof of sole ownership.
    if(matching.length>1)return null;
  }
  return null;
}
function modelProposal(state,peer,symbol,qty,eventAt,now){
  const last=state.desks?.[peer]?.last||{};
  const correctSide=qty>0?'BUY':'SELL';
  const row=(last.entryAssessments||[]).find(x=>
    x?.symbol===symbol && normAction(x.action)===correctSide &&
    x.thesis && x.confidence>=0 && Number.isFinite(date(x.at||last.at)));
  const headline=last.symbol===symbol && normAction(last.action)===correctSide && last.thesis?last:null;
  const raw=row||headline;
  // A challenge is not actionable without a documented independent model thesis.
  if(!raw || !Number.isFinite(date(eventAt)) || now-date(eventAt)>MAX_REQUEST_MS)
    return {available:false,reason:'No fresh model-authored challenger thesis',direction:correctSide};
  return {available:true,action:correctSide,direction:correctSide,
    at:raw.at||last.at||null,
    confidence:finite(raw.confidence)?raw.confidence:null,
    thesis:String(raw.thesis).slice(0,950),
    invalidation:String(raw.invalidation||'').slice(0,350),
    price:finite(raw.entryPrice)?raw.entryPrice:null,
    requestedLiveQty:qty};
}
function recentOwnerClose(state,owner,symbol,baseline,now){
  const response=state.desks?.[owner]?.last?.researchAssessments?.find(x=>x.symbol===symbol);
  if(response && ['CLOSE','CLOSE_ALL'].includes(normAction(response.action)) &&
    Number.isFinite(date(response.at)) && date(response.at)>=baseline && date(response.at)<=now+5_000)
    return true;
  return (state.desks?.[owner]?.futuresShadow?.trades||[]).some(t=>
    t.symbol===symbol && t.intent==='close' &&
    ['model','model_protection'].includes(t.authority) &&
    Number.isFinite(date(t.at)) && date(t.at)>=baseline && date(t.at)<=now+5_000);
}
function upsertRequest(state,ledger,symbol,owner,peer,peerContribution,now,origin){
  const proposed=modelProposal(state,peer,symbol,peerContribution.qty,peerContribution.eventAt,now);
  const event=String(peerContribution.eventAt||'');
  const requestId=crypto.createHash('sha256').update(JSON.stringify([
    'HOLDER_CONSENT_V2',symbol,owner,peer,event,peerContribution.qty,proposed.thesis||''
  ])).digest('hex').slice(0,40);
  const prior=ledger.requests[symbol];
  const request=prior?.requestId===requestId?prior:{
    requestId,symbol,holder:owner,challenger:peer,
    at:stamp(now),challengerEventAt:event,
    challengerQty:peerContribution.qty,origin,
    proposal:proposed,status:'awaiting_holder',
    holderOptions:['KEEP','REDUCE','RELEASE']
  };
  if(prior?.requestId!==requestId){
    delete ledger.decisions[symbol];
    ledger.requests[symbol]=request;
    ledger.events.push({at:stamp(now),symbol,kind:'REQUEST',holder:owner,challenger:peer,requestId});
    ledger.events=ledger.events.slice(-80);
  }
  return request;
}
export function activeHolderRequest(state,who,{now=Date.now()}={}){
  const l=state.researchLive?.holderConsentV2;
  if(l?.version!==2)return null;
  const candidates=Object.values(l.requests||{}).filter(r=>
    r && r.holder===who && r.status==='awaiting_holder' && r.proposal?.available &&
    Number.isFinite(date(r.at)) && date(r.at)<=now+5_000 && now-date(r.at)<=MAX_REQUEST_MS &&
    Number.isFinite(date(r.challengerEventAt)) && now-date(r.challengerEventAt)<=MAX_REQUEST_MS);
  return candidates.sort((a,b)=>date(a.at)-date(b.at))[0]||null;
}
export function validateHolderDecision(raw,request,{holder,model,at,now=Date.now()}={}){
  if(!raw || typeof raw!=='object' || Array.isArray(raw) || !request?.proposal?.available ||
    !DESKS.includes(holder) || request.holder!==holder || !model)return null;
  if(raw.requestId!==request.requestId || raw.symbol!==request.symbol)return null;
  const decision=normAction(raw.decision);
  if(!['KEEP','REDUCE','RELEASE'].includes(decision))return null;
  const when=date(at);
  if(!Number.isFinite(when) || !Number.isFinite(date(request.at)) ||
     when<date(request.at) || when>now+5000 || now-when>MAX_REPLY_MS ||
     when-date(request.at)>MAX_REQUEST_MS)return null;
  const explanation=String(raw.reason||'').trim().slice(0,800);
  if(explanation.length<12)return null;
  const reduceFraction=decision==='REDUCE'?asNumber(raw.reduceFraction):0;
  if(decision==='REDUCE' && !(reduceFraction>=0.05 && reduceFraction<=0.75))return null;
  return {version:2,requestId:request.requestId,symbol:request.symbol,
    holder,challenger:request.challenger,decision,reduceFraction,
    reason:explanation,model,at:stamp(when),proposalAt:request.challengerEventAt};
}
export function recordHolderDecision(state,holder,modelCall,{now=Date.now()}={}){
  const l=state.researchLive && initLedger(state.researchLive);
  if(!l || !modelCall?.holderDecision || modelCall?.error)return null;
  const raw=modelCall.holderDecision;
  const request=l.requests[raw.symbol];
  const normalized=validateHolderDecision(raw,request,{holder,model:modelCall.model,at:modelCall.at,now});
  if(!normalized)return null;
  // Only the current requestId may receive authority. A stale model answer is a veto.
  if(request.requestId!==normalized.requestId)return null;
  const ex=state.exchange||{};
  const accountAge=now-date(ex.at);
  if(ex.connected!==true || ex.positionsStale===true ||
     !Number.isFinite(accountAge) || accountAge<0 || accountAge>180_000)return null;
  const live=ex.positions?.find(p=>p.symbol===request.symbol);
  const amt=Number(live?.amt||0);
  const owner=l.owners[request.symbol];
  if(!owner || owner.desk!==holder || !amt || SIGN(owner.direction)!==SIGN(amt))return null;
  // RELEASE must appear alongside the holder's own model-authored CLOSE
  // assessment. A free-floating JSON consent field cannot bypass book accounting.
  const assessed=(modelCall.researchAssessments||[]).find(x=>x.symbol===request.symbol);
  if(normalized.decision==='RELEASE' &&
    (!assessed || !['CLOSE','CLOSE_ALL'].includes(normAction(assessed.action)) ||
     assessed.error || assessed.authority!=='model'))return null;
  if(normalized.decision==='REDUCE'){
    normalized.maxAbsQty=Math.abs(amt)*(1-normalized.reduceFraction);
    normalized.initialLiveQty=amt;
  }
  l.decisions[request.symbol]=normalized;
  if(normalized.decision==='RELEASE')l.suppressed[request.symbol]={desk:holder,after:normalized.at,requestId:normalized.requestId};
  request.status='answered';
  request.answeredAt=normalized.at;
  l.events.push({at:normalized.at,symbol:request.symbol,kind:normalized.decision,
    holder,challenger:normalized.challenger,requestId:normalized.requestId,
    reason:normalized.reason});
  l.events=l.events.slice(-80);
  return normalized;
}
// After an explicit RELEASE, an old research-book holding must not reappear
// simply because ownership reconciliation restored its historic shadow entry.
export function holderSuppressedContribution(state,mirror,symbol,c,now=Date.now()){
  const rec=mirror?.holderConsentV2?.suppressed?.[symbol];
  if(!rec || c?.desk!==rec.desk || !c.qty)return false;
  const event=date(c.eventAt);
  return !Number.isFinite(event) || event<=date(rec.after) ||
    !modelProposal(state,c.desk,symbol,c.qty,c.eventAt,now).available;
}
// Plan target: no netting, no implicit holder consent, and no stale re-open.
export function holderFirstTarget(state,mirror,symbol,contributions,current,now=Date.now()){
  const desired=contributions.reduce((n,c)=>n+Number(c.qty||0),0);
  if(!finite(current)||contributions.some(c=>!finite(c.qty)))
    return {qty:current||0,reason:`${symbol}: invalid research quantity, normal synchronization frozen`};
  const l=initLedger(mirror);
  if(!l)return {qty:current,reason:`${symbol}: ownership ledger unavailable`};
  const active=contributions.filter(c=>c.qty!==0 && !holderSuppressedContribution(state,mirror,symbol,c,now));
  let owner=l.owners[symbol]||null;
  if(current===0){
    if(owner)owner.flatSince ||=stamp(now);
    if(active.length>1)return {qty:0,reason:`${symbol}: multiple desks want flat coin; owner decision required`};
    if(!active.length)return {qty:0};
    const c=active[0];
    if(owner){
      const event=date(c.eventAt);
      if(!Number.isFinite(event)||event<=date(owner.flatSince)||event>now+5000||now-event>MAX_ENTRY_MS)
        return {qty:0,reason:`${symbol}: new entry must follow observed Binance flat timestamp`};
      if(c.desk!==owner.desk && !owner.releasedAt)
        return {qty:0,reason:`${symbol}: holder has not authorized the handoff`};
      l.owners[symbol]={desk:c.desk,direction:SIGN(c.qty),openedAt:stamp(now)};
      if(l.suppressed[symbol]?.desk===c.desk)delete l.suppressed[symbol];
      delete l.decisions[symbol];delete l.requests[symbol];
    }
    return {qty:c.qty};
  }
  const direction=SIGN(current);
  if(owner && direction!==owner.direction)
    return {qty:current,reason:`${symbol}: exchange disagrees with recorded holder, normal orders frozen`};
  if(!owner){
    const proof=ownerFromConfirmedEntry(state,symbol,direction);
    const same=active.filter(c=>SIGN(c.qty)===direction);
    if(!proof){
      // No claim of ownership based only on conflicting, mutable model positions.
      if(active.length>1 || active.some(c=>SIGN(c.qty)!==direction))
        return {qty:current,reason:`${symbol}: incumbent owner unverified; conflicting orders frozen`};
      return {qty:desired};
    }
    owner={desk:proof,direction,openedAt:stamp(now)};
    l.owners[symbol]=owner;
  }
  const held=contributions.find(c=>c.desk===owner.desk);
  const others=active.filter(c=>c.desk!==owner.desk);
  const challenged=others.length>0 || Boolean(l.requests[symbol]);
  if(!challenged){
    // A non-conflicted owner's management follows existing behavior, while a
    // previously consented cap may never be silently undone by netting.
    const grant=l.decisions[symbol];
    if(grant?.decision==='REDUCE'){
      const amount=Math.min(Math.abs(current),Math.abs(held?.qty||0),grant.maxAbsQty);
      return {qty:direction*amount,reason:`${symbol}: holder-authorized reduction ceiling`};
    }
    return {qty:desired};
  }
  const peer=others[0];
  const request=peer?upsertRequest(state,l,symbol,owner.desk,peer.desk,peer,now,owner.openedAt):l.requests[symbol];
  const approved=l.decisions[symbol];
  const valid=Boolean(approved && request && approved.requestId===request.requestId &&
    approved.holder===owner.desk && Number.isFinite(date(approved.at)) &&
    date(approved.at)>=date(request.at) && date(approved.at)<=now+5000 &&
    now-date(approved.at)<=MAX_REQUEST_MS);
  if(valid && approved.decision==='RELEASE'){
    owner.releasedAt ||=approved.at;
    return {qty:0,reason:`${symbol}: holder ${owner.desk} RELEASE approved; closing before handoff`,kind:'holder_release'};
  }
  if(valid && approved.decision==='REDUCE'){
    const bound=Math.max(0,Math.min(Math.abs(current),Math.abs(held?.qty||current),approved.maxAbsQty));
    return {qty:direction*bound,reason:`${symbol}: holder ${owner.desk} REDUCE approved`,kind:'holder_reduce'};
  }
  if(held?.qty && SIGN(held.qty)===direction){
    const amount=Math.min(Math.abs(current),Math.abs(held.qty));
    return {qty:direction*amount,reason:`${symbol}: holder ${owner.desk} ${valid?'KEEP':'approval pending'}; peer blocked`,kind:'holder_keep'};
  }
  if(!held?.qty && recentOwnerClose(state,owner.desk,symbol,date(owner.openedAt),now)){
    owner.releasedAt ||=stamp(now);
    return {qty:0,reason:`${symbol}: holder independently closed its research position`,kind:'holder_close'};
  }
  return {qty:current,reason:`${symbol}: holder permission missing; peer blocked`,kind:'holder_keep'};
}
export function holderFirstOrderError(state,order,{now=Date.now()}={}){
  if(!order?.researchMirror || !state.researchLive)return null;
  const symbol=order.symbol;
  const t=state.researchLive.targets?.find(x=>x.symbol===symbol);
  const e=order.researchMirror;
  if(!t || t.signature!==e.signature || e.symbol!==symbol)
    return 'HOLDER_CONSENT_V2: missing persisted research target';
  if(!less(t.qty,e.targetQty))return 'HOLDER_CONSENT_V2: order target differs from persisted target';
  const mirror=structuredClone(state.researchLive);
  const context=structuredClone(state);
  const current=Number(state.exchange?.positions?.find(p=>p.symbol===symbol)?.amt||0);
  const gate=holderFirstTarget(context,mirror,symbol,t.contributions,current,now);
  const permitted=state.researchLive.blocked?.[symbol]?0:gate.qty;
  if(!less(permitted,e.targetQty))return 'HOLDER_CONSENT_V2: live position or holder authorization changed';
  if(order.reduce){
    if(!current || SIGN(current)===(order.side==='buy'?1:-1))
      return 'HOLDER_CONSENT_V2: reduce-only side mismatch';
    if(order.qty>Math.abs(current)+1e-8)return 'HOLDER_CONSENT_V2: reduction exceeds live position';
    if(permitted && SIGN(permitted)!==SIGN(current))return 'HOLDER_CONSENT_V2: reversal cannot be a reduction target';
    const allowed=Math.abs(current)-Math.abs(permitted);
    if(!(allowed>0) || order.qty>allowed+Math.max(1e-8,allowed*1e-9))
      return 'HOLDER_CONSENT_V2: reduction exceeds holder-authorized delta';
  } else {
    if(state.livePaused)return 'HOLDER_CONSENT_V2: new exposure disarmed';
    if(current && SIGN(current)!==SIGN(permitted))return 'HOLDER_CONSENT_V2: reverse entry before flat';
    const delta=permitted-current,side=order.side==='buy'?1:-1;
    if(SIGN(delta)!==side || !(Math.abs(delta)>0) ||
       order.qty>Math.abs(delta)+Math.max(1e-8,Math.abs(delta)*1e-9))
      return 'HOLDER_CONSENT_V2: order exceeds authorized opening delta';
  }
  return null;
}

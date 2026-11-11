import assert from 'node:assert/strict';
import {holderFirstTarget,activeHolderRequest,validateHolderDecision,recordHolderDecision,holderFirstOrderError} from './research-holder-consent-v2.mjs';
const T=Date.parse('2026-11-11T14:10:00.000Z');
const at=n=>new Date(T+n).toISOString();
const make=(live=-42401)=>({
  livePaused:false,
  directBinance:{orders:{a:{symbol:'AGTUSDT',side:'SELL',reduceOnly:false,status:'filled',createdAt:at(-600000),researchMirror:{contributions:[{desk:'atlas',qty:0},{desk:'oracle',qty:-42401}]}}}},
  exchange:{connected:true,positionsStale:false,at:at(0),positions:[{symbol:'AGTUSDT',amt:live}]},
  desks:{atlas:{last:{at:at(-4000),entryAssessments:[{symbol:'AGTUSDT',action:'buy',at:at(-4000),confidence:0.7,thesis:'Confirmed bullish structure and strong aggressive buying',invalidation:'0.052'}]},futuresShadow:{positions:[{symbol:'AGTUSDT',qty:34000}],trades:[]}},oracle:{last:{at:at(-2000),researchAssessments:[{symbol:'AGTUSDT',action:'hold',at:at(-2000)}]},futuresShadow:{positions:[{symbol:'AGTUSDT',qty:-84802}],trades:[]}}},
  researchLive:{version:1,holderConsentV2:null,targets:[],blocked:{}}
});
const contributions=(atlas=16984,oracle=-42401,ev=at(-5000))=>[{desk:'atlas',qty:atlas,eventAt:ev},{desk:'oracle',qty:oracle,eventAt:at(-600000)}];
let count=0;function e(got,expected,name){assert.deepEqual(got,expected,name);count++;}
const s=make(),mirror=s.researchLive;
let r=holderFirstTarget(s,mirror,'AGTUSDT',contributions(),-42401,T);
e(r.qty,-42401,'Atlas cannot net Oracle');
e(mirror.holderConsentV2.owners.AGTUSDT.desk,'oracle','Opening owner is Oracle');
let q=activeHolderRequest(s,'oracle',{now:T});
e(q.holder,'oracle','Request sent to Oracle');
e(q.challenger,'atlas','Atlas is challenger');
e(q.proposal.available,true,'Real challenger thesis present');
e(q.proposal.action,'BUY','Original challenger direction');
e(activeHolderRequest(s,'atlas',{now:T}),null,'Challenger cannot answer itself');
let keep={symbol:'AGTUSDT',requestId:q.requestId,decision:'KEEP',reduceFraction:0,reason:'Rising trend remains unconfirmed and short thesis holds.'};
e(validateHolderDecision(keep,q,{holder:'atlas',model:'gemini-3.5-flash-lite',at:at(2000),now:T+3000}),null,'Wrong holder cannot authorize');
e(validateHolderDecision({...keep,requestId:'stale'},q,{holder:'oracle',model:'gemini-3.5-flash-lite',at:at(2000),now:T+3000}),null,'Stale request rejected');
e(validateHolderDecision({...keep,decision:'REDUCE',reduceFraction:0.95},q,{holder:'oracle',model:'gemini-3.5-flash-lite',at:at(2000),now:T+3000}),null,'Oversized reduction blocked');
e(validateHolderDecision({...keep,decision:'RELEASE',reason:''},q,{holder:'oracle',model:'gemini-3.5-flash-lite',at:at(2000),now:T+3000}),null,'Empty reasoning blocked');
e(validateHolderDecision(keep,q,{holder:'oracle',model:'gemini-3.5-flash-lite',at:at(-2000),now:T+3000}),null,'Pre-request decision blocked');
s.desks.oracle.last={at:at(2000),model:'gemini-3.5-flash-lite',holderDecision:keep,researchAssessments:[{symbol:'AGTUSDT',action:'hold',at:at(2000)}]};
e(recordHolderDecision(s,'oracle',s.desks.oracle.last,{now:T+3000}).decision,'KEEP','Oracle KEEP accepted');
e(holderFirstTarget(s,mirror,'AGTUSDT',contributions(),-42401,T+4000).qty,-42401,'KEEP blocks Atlas');
// Holder REDUCE 25% is independent of Atlas requested 40%; cap remains fixed after partial fill.
const s2=make(),m2=s2.researchLive;holderFirstTarget(s2,m2,'AGTUSDT',contributions(),-42401,T);
q=activeHolderRequest(s2,'oracle',{now:T});
const partial={symbol:'AGTUSDT',requestId:q.requestId,decision:'REDUCE',reduceFraction:0.25,reason:'Approve 25 percent de-risking while retaining short thesis.'};
s2.desks.oracle.last={at:at(1000),model:'gemini-3.5-flash-lite',holderDecision:partial};
e(recordHolderDecision(s2,'oracle',s2.desks.oracle.last,{now:T+2000}).decision,'REDUCE','Holder REDUCE accepted');
e(holderFirstTarget(s2,m2,'AGTUSDT',contributions(),-42401,T+2000).qty,-31800.75,'25% reduction not 40%');
e(holderFirstTarget(s2,m2,'AGTUSDT',contributions(),-35000,T+2000).qty,-31800.75,'Pending partial still targets approved qty');
e(holderFirstTarget(s2,m2,'AGTUSDT',contributions(),-31800.75,T+2000).qty,-31800.75,'No repeated decrease');
// Holder RELEASE closes only if holder own research assessment also CLOSEs.
const s3=make(),m3=s3.researchLive;holderFirstTarget(s3,m3,'AGTUSDT',contributions(),-42401,T);
q=activeHolderRequest(s3,'oracle',{now:T});
const rel={symbol:'AGTUSDT',requestId:q.requestId,decision:'RELEASE',reduceFraction:0,reason:'Bullish confirmation invalidates the short thesis; release for handoff.'};
s3.desks.oracle.last={at:at(1000),model:'gemini-3.5-flash-lite',holderDecision:rel};
e(recordHolderDecision(s3,'oracle',s3.desks.oracle.last,{now:T+2000}),null,'Cannot RELEASE without model assessment CLOSE');
s3.desks.oracle.last.researchAssessments=[{symbol:'AGTUSDT',action:'close',authority:'model',at:at(1000)}];
e(recordHolderDecision(s3,'oracle',s3.desks.oracle.last,{now:T+2000}).decision,'RELEASE','Oracle RELEASE accepted after own model CLOSE');
e(holderFirstTarget(s3,m3,'AGTUSDT',contributions(),-42401,T+2000).qty,0,'Release orders flatten');
e(holderFirstTarget(s3,m3,'AGTUSDT',contributions(),0,T+3000).qty,0,'Released owner stale book suppressed; old challenger held');
e(holderFirstTarget(s3,m3,'AGTUSDT',contributions(16984,-42401,at(5000)),0,T+6000).qty,16984,'Fresh challenger after flat can enter despite reattached owner book');
// Guard catches stale/unsafe target and constrains the recorded order.
const safe=make(-42401),sm=safe.researchLive;holderFirstTarget(safe,sm,'AGTUSDT',contributions(),-42401,T);
const t=sm.targets=[{symbol:'AGTUSDT',signature:'sig',qty:-42401,contributions:contributions()}];
const fake={symbol:'AGTUSDT',side:'buy',qty:16984,reduce:true,researchMirror:{version:1,symbol:'AGTUSDT',signature:'sig',targetQty:-25417}};
e(typeof holderFirstOrderError(safe,fake,{now:T}),'string','Order authorization vetoes peer netting');
e(typeof holderFirstOrderError(safe,{...fake,researchMirror:{...fake.researchMirror,targetQty:-42401}},{now:T}),'string','Reject reduction when target unchanged');
const approved=make(-42401),am=approved.researchLive;
holderFirstTarget(approved,am,'AGTUSDT',contributions(),-42401,T);
const qq=activeHolderRequest(approved,'oracle',{now:T});
approved.desks.oracle.last={at:at(1000),model:'gemini',holderDecision:{symbol:'AGTUSDT',requestId:qq.requestId,decision:'REDUCE',reduceFraction:0.25,reason:'Approve small partial reduction with reason.'}};
recordHolderDecision(approved,'oracle',approved.desks.oracle.last,{now:T+2000});
am.targets=[{symbol:'AGTUSDT',signature:'sig',qty:-31800.75,contributions:contributions()}];
e(holderFirstOrderError(approved,{...fake,qty:10600.25,researchMirror:{...fake.researchMirror,targetQty:-31800.75}},{now:T+2000}),null,'Approved reduce-only order passes executor');
e(typeof holderFirstOrderError(approved,{...fake,qty:16984,researchMirror:{...fake.researchMirror,targetQty:-31800.75}},{now:T+2000}),'string','Excess reduction rejected by executor');
// Flat conflict blocks both sign directions.
const flat=make(0);e(holderFirstTarget(flat,flat.researchLive,'AGTUSDT',contributions(),0,T).qty,0,'No simultaneous first entry');
console.log('PASS',count,'consent/ownership assertions');

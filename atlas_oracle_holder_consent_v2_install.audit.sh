#!/usr/bin/env bash
# HOLDER_CONSENT_V2: real model request/reply, holder-authorized netting veto.
# Never interrupts open software-managed positions merely to deploy.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077
BASE_ENGINE=f7dfe635476d3b131221efbbc547f677461185886349c87b1da0683644004133
BASE_PLANNER=188c0c96487ed7971828056772dcaaef6ca33f985bf28f9982bf864b8883154c
COMMIT='fce9cc189f6a2e9cfc6b984059bbde01c13bc9b5'
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACK="$PWD/backups/holder-consent-v2-$STAMP"
mkdir -p "$BACK"
exec 9>/run/lock/twin-desk-holder-consent-v2.lock
flock -n 9 || { echo 'ABORT: another Holder-Consent installer is active'; exit 1; }

echo '=== VERIFY EXACT LIVE CODE AND DOCKER ==='
printf '%s  vps/lib/engine.mjs\n%s  vps/lib/research-live.mjs\n' "$BASE_ENGINE" "$BASE_PLANNER" | sha256sum -c -
docker compose config --quiet
CID="$(docker compose ps -q twin-desk)"; test -n "$CID"
test "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy
for f in engine.mjs research-live.mjs; do
  test "$(sha256sum "vps/lib/$f" | awk '{print $1}')" = "$(docker compose exec -T twin-desk sha256sum "/app/vps/lib/$f" | awk '{print $1}')"
done
test ! -e vps/lib/research-holder-consent-v2.mjs
OLD_IMAGE="$(docker inspect -f '{{.Image}}' "$CID")"
IMAGE_TAG="$(docker inspect -f '{{.Config.Image}}' "$CID")"
cp -a vps/lib/engine.mjs "$BACK/engine.original.mjs"
cp -a vps/lib/research-live.mjs "$BACK/research-live.original.mjs"

echo '=== FETCH PINNED IMPLEMENTATION AND VERIFY SHA256 ==='
fetch(){
  local file="$1" dest="$2" sha="$3"
  curl -fLsS --retry 3 "https://raw.githubusercontent.com/a-garzas2026/atlas-oracle-installers/$COMMIT/$file" | base64 -d | gzip -d > "$dest"
  printf '%s  %s\n' "$sha" "$dest" | sha256sum -c -
}
fetch holder_consent_v2_module.mjs.gz.b64 "$BACK/research-holder-consent-v2.mjs" 11c54ccc381254f29906c13198ecc63abfc3f496844d542cd68294aab9404c86
fetch holder_consent_v2_patcher.py.gz.b64 "$BACK/prepare.py" 38ffaa08a0d41935a7c75f9ef279de31749c7517a9a729d2ebb6a959449bdaa5
fetch holder_consent_v2_test.mjs.gz.b64 "$BACK/test.mjs" 77ebafaa49a5d7de6bc2371a175d47795a0c8d9aadb29cccc70f8faca4255b5c

python3 "$BACK/prepare.py" "$PWD" "$BACK"
cp -a "$BACK/research-holder-consent-v2.mjs" "$BACK/research-holder-consent-v2.staged.mjs"
for f in engine.mjs research-live.mjs research-holder-consent-v2.mjs; do
  if [ "$f" = 'research-holder-consent-v2.mjs' ]; then src="$BACK/research-holder-consent-v2.staged.mjs"; else src="$BACK/$f"; fi
  docker compose exec -T twin-desk node --check --input-type=module < "$src"
done
python3 - "$BACK" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); mod=(p/'research-holder-consent-v2.mjs').read_text(); t=(p/'test.mjs').read_text()
a="import {holderFirstTarget,activeHolderRequest,validateHolderDecision,recordHolderDecision,holderFirstOrderError} from './research-holder-consent-v2.mjs';"
assert t.count(a)==1
(p/'test-bundle.mjs').write_text(mod+'\n'+t.replace(a,''))
print('PASS: offline test bundle contains real protocol source')
PY
# Run tests in the exact existing Node image, with network disabled and no mounts.
docker run --rm -i --network none --read-only --entrypoint node "$OLD_IMAGE" --input-type=module < "$BACK/test-bundle.mjs"
echo "PASS: prepared exact patch and tests in $BACK"

echo '=== VERIFY EXCHANGE HAS NO LIVE POSITION OR UNRESOLVED ORDER ==='
if ! docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=Date.now()-Date.parse(e.at||'');
const flat=e.connected===true && e.positionsStale===false && age>=0 && age<=180000 &&
 Array.isArray(e.positions) && !e.positions.length &&
 Array.isArray(e.openOrders) && !e.openOrders.length &&
 Array.isArray(e.algoOrders) && !e.algoOrders.length &&
 !s.pendingOrders?.length && !s.executionIssue &&
 !Object.values(s.directBinance?.orders||{}).some(x=>['claimed','sending','outcome_unknown'].includes(x.status));
console.log(JSON.stringify({safeToDeploy:flat,livePositions:(e.positions||[]).map(x=>({symbol:x.symbol,amount:x.amt})),entriesPaused:s.livePaused,exchangeAgeSeconds:Math.round(age/1000)}));
if(!flat)process.exit(10);
JS
then
  echo 'STAGED ONLY: live or unverified Binance exposure; NO code, controls, or positions changed.'
  echo 'Do not restart a software-protected open-position container for this upgrade.'
  echo "Source prepared: $BACK"
  exit 0
fi

echo '=== PAUSE NEW ENTRIES; KEEP EXISTING MANAGEMENT ==='
ORIGINAL_PAUSED="$(docker compose exec -T twin-desk node -e "const s=require('/app/data/clean-v1-state.json');process.stdout.write(String(s.livePaused===true))")"
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
await setEntriesPaused(true);
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=Date.now()-Date.parse(e.at||'');
if(!s.livePaused || !e.connected || e.positionsStale || age<0 || age>180000 ||
(e.positions||[]).length || (e.openOrders||[]).length || (e.algoOrders||[]).length ||
s.pendingOrders?.length || s.executionIssue)throw Error('ABORT: not paused, connected and flat');
console.log('PASS: entries paused and exchange still flat');
JS
ROLLBACK="twin-desk:rollback-holder-consent-v2-$STAMP"
docker image tag "$OLD_IMAGE" "$ROLLBACK"
APPLIED=0; RECREATED=0; COMPLETE=0
recover(){
  local rc=$?
  if [ "$COMPLETE" != 1 ]; then
    echo "ABORT ($rc): restoring original engine and planner. Entries stay PAUSED."
    if [ "$APPLIED" = 1 ]; then
      cp -a "$BACK/engine.original.mjs" vps/lib/engine.mjs || true
      cp -a "$BACK/research-live.original.mjs" vps/lib/research-live.mjs || true
      rm -f vps/lib/research-holder-consent-v2.mjs
    fi
    docker image tag "$ROLLBACK" "$IMAGE_TAG" || true
    if [ "$RECREATED" = 1 ]; then docker compose up -d --no-deps --force-recreate twin-desk || true; fi
    echo "Backup: $BACK"
  fi
}
trap recover EXIT
printf '%s  vps/lib/engine.mjs\n%s  vps/lib/research-live.mjs\n' "$BASE_ENGINE" "$BASE_PLANNER" | sha256sum -c -
APPLIED=1
cp -a "$BACK/engine.mjs" vps/lib/engine.mjs
cp -a "$BACK/research-live.mjs" vps/lib/research-live.mjs
cp -a "$BACK/research-holder-consent-v2.staged.mjs" vps/lib/research-holder-consent-v2.mjs

echo '=== BUILD AND VERIFY NEW IMAGE BEFORE RESTART ==='
docker compose build twin-desk
for f in engine.mjs research-live.mjs research-holder-consent-v2.mjs; do
  localsha="$(sha256sum "vps/lib/$f" | awk '{print $1}')"
  imagesha="$(docker run --rm --network none --read-only --entrypoint sha256sum "$IMAGE_TAG" "/app/vps/lib/$f" | awk '{print $1}')"
  test "$localsha" = "$imagesha" || { echo "ABORT: image source mismatch: $f"; exit 1; }
done
docker run --rm --network none --read-only --entrypoint node "$IMAGE_TAG" --input-type=module -e  "import('/app/vps/lib/research-live.mjs').then(m=>{if(typeof m.planResearchLive!=='function')process.exit(1);console.log('PASS: full planner module links')})"
# The paused engine must STILL be flat; never interrupt open software-managed positions.
docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8'));const e=s.exchange||{};
const age=Date.now()-Date.parse(e.at||'');
if(!s.livePaused||!e.connected||e.positionsStale||age<0||age>180000||(e.positions||[]).length||
(e.openOrders||[]).length||(e.algoOrders||[]).length||s.pendingOrders?.length||s.executionIssue)
throw Error('ABORT: exchange changed during build');
console.log('PASS: paused and verified-flat immediately before restart');
JS
RECREATED=1
docker compose up -d --no-deps --force-recreate twin-desk
NEWCID="$(docker compose ps -q twin-desk)"; test -n "$NEWCID"
for _ in $(seq 1 60); do
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID" 2>/dev/null || true)" = healthy ]; then break; fi
  sleep 5
done
test "$(docker inspect -f '{{.State.Health.Status}}' "$NEWCID")" = healthy
for f in engine.mjs research-live.mjs research-holder-consent-v2.mjs; do
  test "$(sha256sum "vps/lib/$f" | awk '{print $1}')" = "$(docker compose exec -T twin-desk sha256sum "/app/vps/lib/$f" | awk '{print $1}')"
done

echo '=== WAIT FOR POST-RESTART SCANNER AND EXCHANGE SNAPSHOT ==='
STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$NEWCID")"
READY=0
for _ in $(seq 1 76); do
 if docker compose exec -T -e STARTED="$STARTED" twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
const age=x=>Date.now()-Date.parse(x||'');
const ok=s.livePaused===true&&s.tradingControl?.status==='running'&&e.connected===true&&e.positionsStale===false&&
age(e.at)>=0&&age(e.at)<=180000&&age(s.market?.asOf)>=0&&age(s.market?.asOf)<=300000&&
Date.parse(s.market?.asOf||'')>=Date.parse(process.env.STARTED||'')&&Object.keys(s.market?.symbols||{}).length>0&&
Array.isArray(e.positions)&&!e.positions.length&&Array.isArray(e.openOrders)&&!e.openOrders.length&&
Array.isArray(e.algoOrders)&&!e.algoOrders.length&&!s.pendingOrders?.length&&!s.executionIssue&&
!Object.values(s.directBinance?.orders||{}).some(x=>['claimed','sending','outcome_unknown'].includes(x.status));
console.log(JSON.stringify({ready:ok,marketAgeSeconds:Math.round(age(s.market?.asOf)/1000),exchangeAgeSeconds:Math.round(age(e.at)/1000)}));
process.exit(ok?0:10);
JS
 then READY=1; break; fi
 sleep 15
done
test "$READY" = 1 || { echo 'ABORT: post-restart scanner/exchange not fresh'; exit 1; }
if [ "$ORIGINAL_PAUSED" = false ]; then
  docker compose exec -T twin-desk node --input-type=module <<'JS'
import fs from 'node:fs';import {setEntriesPaused} from '/app/vps/lib/engine.mjs';
const s=JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')),e=s.exchange||{};
if(s.livePaused!==true||s.tradingControl?.status!=='running'||!e.connected||e.positionsStale||(e.positions||[]).length||
(e.openOrders||[]).length||(e.algoOrders||[]).length||s.pendingOrders?.length||s.executionIssue)throw Error('Final activation blocked');
await setEntriesPaused(false);
if(JSON.parse(fs.readFileSync('/app/data/clean-v1-state.json','utf8')).livePaused!==false)throw Error('Activation failed');
console.log('PASS: independent Demo trading entries re-enabled');
JS
fi
COMPLETE=1;trap - EXIT
echo '=== HOLDER CONSENT V2 DEPLOYED ==='
echo 'Atlas and Oracle Gemini disagreement: holder must explicitly KEEP, REDUCE or RELEASE.'
echo 'Approvals are tied to request IDs, genuine model responses and exchange order checks.'
echo "Backup: $BACK"
docker compose ps twin-desk

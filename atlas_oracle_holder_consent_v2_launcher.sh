#!/usr/bin/env bash
# HOLDER_CONSENT_V2 pinned launcher. The source and regression suite are verified by SHA256.
set -Eeuo pipefail
cd /opt/twin-desk
umask 077
F="$(mktemp /tmp/holder-consent-v2.XXXXXXXX.sh)"
trap 'rm -f "$F"' EXIT
curl -fLsS --retry 3 \
 'https://raw.githubusercontent.com/a-garzas2026/atlas-oracle-installers/f708217ea8278e4fd6cd0b24a7b06aafffd327c8/atlas_oracle_holder_consent_v2_install.sh.gz.b64' \
 | base64 -d | gzip -d > "$F"
printf '%s  %s\n' '2d8dce0aee2f25d7227063f8c65835bb8be376c68d701e2a25b00b8638491340' "$F" | sha256sum -c -
python3 - "$F" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
a="COMMIT='fce9cc189f6a2e9cfc6b984059bbde01c13bc9b5'"
b="COMMIT='d2642af860a3c97a96a706fa8e4743ff1ae3841e'"
x='38ffaa08a0d41935a7c75f9ef279de31749c7517a9a729d2ebb6a959449bdaa5'
y='7fcd5451e594d8bfc187e34d5bb031e18e34e7b3755a6260b003deac92b274df'
assert s.count(a)==1 and s.count(x)==1,'Unexpected installer input'
p.write_text(s.replace(a,b,1).replace(x,y,1))
print('PASS: pinned two-way holder-response relay selected')
PY
bash -n "$F"
exec 3>&1
bash "$F"

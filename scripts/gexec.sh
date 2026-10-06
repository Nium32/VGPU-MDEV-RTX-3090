#!/bin/bash
# gexec.sh <vmid>   reads a PowerShell script on stdin, runs it in the guest, prints output.
# The script is passed as -EncodedCommand (UTF-16LE base64) so no quoting survives to be mangled.
set -euo pipefail
V=${1:?vmid}
SCRIPT=$(cat)
ENC=$(printf '%s' "$SCRIPT" | python3 -c 'import sys,base64;sys.stdout.write(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())')
qm guest exec "$V" --timeout 600 -- powershell -NoProfile -EncodedCommand "$ENC" > /tmp/gexec.json 2>&1 || true
python3 - <<'PY'
import json, sys
try:
    raw = open("/tmp/gexec.json").read()
except OSError as e:
    print("gexec: no agent response (%s)" % e); sys.exit(1)
try:
    d = json.loads(raw)
except Exception:
    print(raw); sys.exit()
for k in ("out-data", "err-data"):
    v = d.get(k)
    if v:
        sys.stdout.write(v if isinstance(v, str) else str(v))
if d.get("exitcode"):
    print("[exitcode %s]" % d["exitcode"])
PY
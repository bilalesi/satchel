#!/bin/zsh
# With Vault.app running, send one native-messaging "hello" through vault-host and print the reply.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Vault.app}"
HOST="$APP/Contents/MacOS/vault-host"
ORIGIN="chrome-extension://$(cat extension/src/.chromium-id)/"
python3 - "$HOST" "$ORIGIN" <<'PY'
import json, struct, subprocess, sys, signal
signal.signal(signal.SIGALRM, lambda *_: (print('TIMEOUT: no reply from app'), sys.exit(2)))
signal.alarm(20)
host, origin = sys.argv[1], sys.argv[2]
p = subprocess.Popen([host, origin], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def send(obj):
    data = json.dumps(obj).encode()
    p.stdin.write(struct.pack("<I", len(data)) + data); p.stdin.flush()
def recv():
    n = struct.unpack("<I", p.stdout.read(4))[0]
    return json.loads(p.stdout.read(n))
send({"id": 1, "type": "hello"}); r1 = recv(); print("hello →", r1)
send({"id": 2, "type": "match", "url": "https://accounts.google.com/signin"}); r2 = recv(); print("match →", r2)
p.stdin.close(); p.wait(timeout=5)
assert r1.get("ok") is True and r1.get("version") == "1", r1
assert r2.get("ok") is True, r2
print("bridge OK (locked=%s)" % r1.get("locked"))
PY

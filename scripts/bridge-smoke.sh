#!/bin/zsh
# With Satchel.app running, send one native-messaging "hello" through satchel-host and print the reply.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Satchel.app}"
HOST="$APP/Contents/MacOS/satchel-host"
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
def ask(i, **kw):
    send({"id": i, **kw}); return recv()
r1 = ask(1, type="hello"); print("hello →", r1)
assert r1.get("ok") is True and r1.get("version") == "1", r1
info = r1.get("info") or {}
print("info →", info)
assert info.get("workspace") and info.get("sync", {}).get("state"), info
r2 = ask(2, type="match", url="https://accounts.google.com/signin"); print("match →", r2)
assert r2.get("ok") is True, r2
if r1.get("locked"):
    print("bridge OK (locked: unlock the app to exercise search/copy/code)")
else:
    assert info.get("items") is not None, "unlocked status must carry counts"
    r3 = ask(3, type="search", query="a", limit=3); print("search →", r3)
    assert r3.get("ok") and len(r3.get("items", [])) <= 3, r3
    assert "password" not in json.dumps(r3).lower().replace('"password": null', ''), "search must not carry secrets"
    r4 = ask(4, type="copy", itemID=(r3["items"] or [{"id": "00000000-0000-0000-0000-000000000000"}])[0]["id"], field="bogus"); print("copy bogus →", r4)
    assert r4.get("ok") is False and r4.get("error") == "bad_field", r4
    r5 = ask(5, type="code", itemID="00000000-0000-0000-0000-000000000000"); print("code unknown →", r5)
    assert r5.get("ok") is False, r5
    r6 = ask(6, type="lock"); print("lock →", r6)
    assert r6.get("locked") is True and r6.get("info", {}).get("items") is None, r6
    print("bridge OK (unlocked paths, then locked)")
p.stdin.close(); p.wait(timeout=5)
PY

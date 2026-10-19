#!/bin/bash
set -euo pipefail
umask 077

[ "$#" = 2 ] && [ "$2" = --disposable-host ] || {
    echo "usage: test-clean-installed-workflow.sh /absolute/downloads --disposable-host" >&2
    exit 2
}
[ "$(id -u)" = 0 ] || { echo "requires root on the disposable test host" >&2; exit 1; }
downloads=$1
[[ "$downloads" = /* ]] && [ -d "$downloads" ] && [ ! -L "$downloads" ] ||
    { echo "requires an absolute non-symlink downloads directory" >&2; exit 1; }
installer="$downloads/zpr-cli"
test -f "$installer" && test ! -L "$installer"
release=demo-runtime-20261018-1631
project=zprdemo-edb83674f83e
image=sha256:660a7907dbb98150e49e9f99627b8410666d6205ce719334ad498861756210f5
stamp=$(date -u +%Y%m%dT%H%M%SZ)
(
    cd "$downloads"
    printf '%s\n' \
        '4d8e352a36448767a39c5ccbe1dd78831420abe0b070c2cf751a4532495fd2f6  zpr-demo-demo-runtime-20261018-1631.tar' \
        '41e2e72e7232b102629c4d4e8f0509d86e2db85f3035a5664cd77c592197a462  simulator-demo-runtime-20261018-1631.tar' \
        '8f9dbbc3ea177729e92228dfa6f5a7dbda70615527b8ae761b63ed8f1808ab5f  simulator-scenario-admission-20261019-r6.tar' |
        sha256sum --check --strict -
)

# Refuse an unknown environment before stopping anything.
for service in node0 node1 vs web0 web1 alice; do
    name="$project-$service-1"
    actual=$(docker inspect --format '{{.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' "$name")
    [ "$actual" = "$image|$project|$service" ] ||
        { echo "unexpected runtime container: $name" >&2; exit 1; }
done
for name in zpr-operator-room zpr-operator-service zpr-operator-policy; do
    actual=$(docker inspect --format '{{.Image}}|{{index .Config.Labels "zpr.operator.state"}}' "$name")
    case "$actual" in
        "$image|/home/dubnom/zpr-operator-state"|"$image|/var/lib/zpr-demo-state/operator") ;;
        *) echo "unexpected existing operator installation: $name" >&2; exit 1 ;;
    esac
done

bash "$installer" simulator-stop
for name in zpr-operator-room zpr-operator-service zpr-operator-policy; do
    docker stop --time 15 "$name" >/dev/null
    docker rename "$name" "$name-before-clean-$stamp"
done
docker stop --time 15 zpr-simulator-demo-demo-runtime-20261018-1631 >/dev/null
bash "$installer" stop
# Preserve existing credentials, drafts and network state; do not reuse them.
python3 - "$release" "$stamp" <<'PY'
import os
from pathlib import Path
import stat
import sys

release, stamp = sys.argv[1:]
for path in (
    Path("/opt/zpr-demo") / release,
    Path("/var/lib/zpr-demo-state/zpr-demo"),
    Path("/var/lib/zpr-demo-state/simulator-acceptance"),
    Path("/var/lib/zpr-demo-state/operator"),
):
    if path.name == "operator" and not path.exists():
        continue
    info = path.lstat()
    forbidden = 0o022 if path.parent == Path("/opt/zpr-demo") else 0o077
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & forbidden:
        raise SystemExit("unsafe backup source: " + str(path))
    backup = path.with_name(path.name + "-before-clean-" + stamp)
    if backup.exists() or backup.is_symlink():
        raise SystemExit("backup already exists: " + str(backup))
    os.rename(path, backup)
    print("Retained prior installation/state: " + str(backup))
PY
# The stopped managed Simulator belongs to the old state; retain it for rollback.
docker rename zpr-simulator-acceptance "zpr-simulator-acceptance-before-clean-$stamp"

echo "Beginning clean-state installation; failures retain new and prior state for inspection."
bash "$installer" install "$downloads"
bash "$installer" start --disposable-host
bash "$installer" smoke
bash "$installer" operator-start
identity_fingerprint() {
    python3 - <<'PY'
import hashlib
from pathlib import Path

digest = hashlib.sha256()
for directory in (Path("/var/lib/zpr-demo-state/zpr-demo/include"),
                  Path("/var/lib/zpr-demo-state/zpr-demo/conf")):
    files = sorted(path for path in directory.rglob("*") if path.is_file())
    if not files:
        raise SystemExit("identity/configuration inventory is empty")
    for path in files:
        digest.update(str(path).encode() + b"\0" + path.read_bytes())
print(digest.hexdigest())
PY
}
before_identities=$(identity_fingerprint)
before_policy=$(docker exec "$project-vs-1" redis-cli -e --json HGETALL policy:current)
draft=$(python3 - <<'PY'
import json
import urllib.request

base = "http://127.0.0.1:8787"
def post(path, body):
    request = urllib.request.Request(base + path, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Origin": base})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)
category = post("/api/policy/categories", {"name": "Clean installation acceptance"})
record = post("/api/policy/records", {"category_id": category["id"], "name": "Restart acceptance",
    "kind": "policy", "content": "# clean installation revision one\n", "summary": "Acceptance seed"})
post("/api/policy/records/" + record["id"] + "/revisions",
    {"content": "# clean installation revision two\n", "expected_revision": 1, "summary": "Restart evidence"})
print(record["id"])
PY
)
bash "$installer" simulator-install "$downloads/simulator-scenario-admission-20261019-r6.tar"
bash "$installer" simulator-start --disposable-host
bash "$installer" simulator-test
bash "$installer" simulator-stop
bash "$installer" operator-stop
bash "$installer" stop
bash "$installer" start --disposable-host
bash "$installer" smoke
bash "$installer" operator-start
bash "$installer" simulator-start --disposable-host
bash "$installer" simulator-test
[ "$before_identities" = "$(identity_fingerprint)" ] ||
    { echo "identity/configuration inventory changed across restart" >&2; exit 1; }
[ "$before_policy" = "$(docker exec "$project-vs-1" redis-cli -e --json HGETALL policy:current)" ] ||
    { echo "active policy changed across restart" >&2; exit 1; }
python3 - "$draft" <<'PY'
import json
import urllib.error
import urllib.request
import sys

base = "http://127.0.0.1:8787"
path = "/api/policy/records/" + sys.argv[1]
with urllib.request.urlopen(base + path, timeout=15) as response:
    record = json.load(response)
assert record["current_revision"] == 2, record
assert record["content"] == "# clean installation revision two\n", record
request = urllib.request.Request(base + path + "/revisions",
    data=json.dumps({"content": "# stale revision\n", "expected_revision": 1, "summary": "Must reject"}).encode(),
    headers={"Content-Type": "application/json", "Origin": base})
try:
    urllib.request.urlopen(request, timeout=15)
except urllib.error.HTTPError as error:
    assert error.code == 409, error.code
else:
    raise AssertionError("stale draft save accepted")
print("PASS: saved draft revision persisted and stale edits rejected after restart")
PY
bash "$installer" status
bash "$installer" operator-status
bash "$installer" simulator-status
echo "PASS: clean-state installed workflow and full service restart; prior state retained"

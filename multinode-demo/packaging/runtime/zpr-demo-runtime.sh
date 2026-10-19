#!/bin/sh
set -eu
umask 077

fail() {
    printf 'zpr-demo-runtime: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
usage: zpr-demo-runtime.sh start|stop|status|smoke
all runtime commands require sudo on an isolated disposable demo host because
the persistent state and container workloads are root-owned. start prepares
target-local identities and starts the ZPR demo.
smoke sends an HTTP request from Alice through ZPR to web0.
This package does not build or pull images; use only on an isolated demo host.
EOF
}

command_name=${1:-}
case "$command_name" in
    start|stop|status|smoke) ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

: "${ZPR_DEMO_PACKAGE_DIR:?set ZPR_DEMO_PACKAGE_DIR to the installed zpr-demo package}"
: "${ZPR_DEMO_STATE_DIR:?set ZPR_DEMO_STATE_DIR to a persistent private directory}"

command -v python3 >/dev/null 2>&1 || fail "python3 is required to validate package and state paths"
package_metadata=$(
    python3 - "$ZPR_DEMO_PACKAGE_DIR" "$ZPR_DEMO_STATE_DIR" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

package, state = sys.argv[1:]
safe_path = re.compile(r"^[A-Za-z0-9_./-]+$")
release_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$")
reference_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@+-]{0,254}$")
image_id_pattern = re.compile(r"^sha256:[0-9a-f]{64}$")

if (
    not os.path.isabs(package)
    or os.path.normpath(package) != package
    or not safe_path.fullmatch(package)
    or os.path.realpath(package) != package
    or os.path.basename(package) != "zpr-demo"
    or not os.path.isdir(package)
):
    raise SystemExit("ZPR_DEMO_PACKAGE_DIR must be a canonical installed package directory")
if (
    not os.path.isabs(state)
    or os.path.normpath(state) != state
    or state == "/"
    or not safe_path.fullmatch(state)
):
    raise SystemExit("ZPR_DEMO_STATE_DIR must be a canonical absolute path without spaces or colons")

release = os.path.basename(os.path.dirname(package))
if not release_pattern.fullmatch(release):
    raise SystemExit("installed package directory does not contain a valid release ID")
if not os.path.exists(os.path.dirname(state)):
    raise SystemExit("ZPR_DEMO_STATE_DIR parent must already exist")
if os.path.realpath(os.path.dirname(state)) != os.path.dirname(state):
    raise SystemExit("ZPR_DEMO_STATE_DIR parent must not contain symlinks")
if os.path.exists(state):
    info = os.lstat(state)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit("ZPR_DEMO_STATE_DIR must be a non-symlink directory")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise SystemExit("ZPR_DEMO_STATE_DIR must be invoking-user-owned with mode 0700")
state_real = os.path.realpath(state)
if (
    state_real == package
    or state_real.startswith(package + os.sep)
    or package.startswith(state_real + os.sep)
):
    raise SystemExit("package and persistent state directories must be separate")

runtime = os.path.join(package, "runtime")
try:
    with open(os.path.join(package, "manifest.json"), "rb") as source:
        manifest = json.load(source)
    with open(os.path.join(runtime, "image-reference"), "rb") as source:
        reference_bytes = source.read()
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"cannot read installed package metadata: {exc}")

component = manifest.get("component") if isinstance(manifest, dict) else None
reference = component.get("image_reference") if isinstance(component, dict) else None
image_id = component.get("docker_image_id") if isinstance(component, dict) else None
if (
    not isinstance(manifest, dict)
    or manifest.get("schema") != "zpr.demo.runtime-package.v2"
    or manifest.get("status") != "demo-unqualified-runtime-package"
    or manifest.get("platform") != "linux/amd64"
    or manifest.get("package_id") != "zpr-demo-image"
    or manifest.get("required_peer_package_id") != "simulator-image"
    or manifest.get("release_id") != release
    or not isinstance(component, dict)
    or component.get("id") != "zpr-demo-image"
    or not isinstance(reference, str)
    or not reference_pattern.fullmatch(reference)
    or not isinstance(image_id, str)
    or not image_id_pattern.fullmatch(image_id)
    or not isinstance(component.get("image_id"), str)
    or not image_id_pattern.fullmatch(component["image_id"])
    or reference_bytes != (reference + "\n").encode("ascii")
):
    raise SystemExit("manifest, release directory, or image-reference does not identify this ZPR package")

project = "zprdemo-" + hashlib.sha256(release.encode("ascii")).hexdigest()[:12]
for value in (package, state, release, reference, image_id, project):
    print(value)
PY
) || fail "invalid installed package or state path"

PACKAGE_DIR=$(printf '%s\n' "$package_metadata" | sed -n '1p')
STATE_DIR=$(printf '%s\n' "$package_metadata" | sed -n '2p')
RELEASE_ID=$(printf '%s\n' "$package_metadata" | sed -n '3p')
IMAGE_REFERENCE=$(printf '%s\n' "$package_metadata" | sed -n '4p')
IMAGE_ID=$(printf '%s\n' "$package_metadata" | sed -n '5p')
PROJECT_NAME=$(printf '%s\n' "$package_metadata" | sed -n '6p')
RUNTIME_DIR=$PACKAGE_DIR/runtime
COMPOSE_FILE=$RUNTIME_DIR/zpr-demo-compose.yml
STATE_MARKER=$STATE_DIR/.zpr-demo-state-v1
POLICY_MARKER=$STATE_DIR/state/redis/.zpr-demo-policy-v1
POLICY_PENDING=$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending

for asset in \
    "$COMPOSE_FILE" \
    "$RUNTIME_DIR/init-demo-identities.sh" \
    "$RUNTIME_DIR/assets/tools/regen-banner.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-alice.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-node0.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-node1.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-vs.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-web0.sh" \
    "$RUNTIME_DIR/assets/entrypoints/entrypoint-web1.sh"; do
    [ -f "$asset" ] && [ ! -L "$asset" ] || fail "required installed runtime asset is missing or unsafe: $asset"
done
[ -x "$RUNTIME_DIR/init-demo-identities.sh" ] || fail "identity initializer must be executable"
command -v docker >/dev/null 2>&1 || fail "Docker CLI is required"

USER_ID=$(id -u) || fail "cannot determine invoking user ID"
GROUP_ID=$(id -g) || fail "cannot determine invoking group ID"
[ "$USER_ID" = 0 ] ||
    fail "all runtime commands require sudo on the disposable demo host because package state is root-owned"
export ZPR_DEMO_PACKAGE_DIR="$PACKAGE_DIR"
export ZPR_DEMO_STATE_DIR="$STATE_DIR"
export ZPR_DEMO_IMAGE_REFERENCE="$IMAGE_REFERENCE"
export ZPR_DEMO_IMAGE_ID="$IMAGE_ID"
export ZPR_DEMO_RELEASE_ID="$RELEASE_ID"
export ZPR_DEMO_PROJECT_NAME="$PROJECT_NAME"
export ZPR_DEMO_UID="$USER_ID"
export ZPR_DEMO_GID="$GROUP_ID"

compose() {
    docker compose \
        --project-name "$PROJECT_NAME" \
        --project-directory "$PACKAGE_DIR" \
        --file "$COMPOSE_FILE" "$@"
}

validate_compose() {
    compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
    compose config --quiet || fail "Docker Compose rejected the installed runtime configuration"
}

validate_loaded_image() {
    image_metadata=$(docker image inspect \
        --format '{{.Id}}|{{.Os}}|{{.Architecture}}' "$IMAGE_REFERENCE") ||
        fail "the package ZPR image is not available in local Docker"
    [ "$image_metadata" = "$IMAGE_ID|linux|amd64" ] ||
        fail "loaded ZPR image does not match the package's pinned Linux/amd64 image identity"
}

validate_complete_state() {
    python3 - "$STATE_DIR" <<'PY'
import os
import stat
import sys

state = sys.argv[1]
if os.path.islink(state) or not os.path.isdir(state):
    raise SystemExit("demo identity state is unavailable or unsafe")
directories = (
    "include", "conf/node0", "conf/node1", "conf/vs", "conf/web0",
    "conf/web1", "conf/alice", "bob", "admin", "state/redis", "logs",
)
for relative in directories:
    path = os.path.join(state, relative)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"unsafe demo state directory: {relative}")
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise SystemExit(f"demo state directory must be invoking-user-owned mode 0700: {relative}")
marker = os.path.join(state, ".zpr-demo-state-v1")
info = os.lstat(marker)
if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_nlink != 1:
    raise SystemExit("complete demo identity-state marker is missing or unsafe")
if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit("complete demo identity-state marker must be invoking-user-owned mode 0600")
PY
}

validate_policy_marker() {
    marker=$1
    expected=$(printf 'zpr-demo-policy-v1\nrelease=%s\nimage=%s\n' "$RELEASE_ID" "$IMAGE_ID")
    [ -f "$marker" ] && [ ! -L "$marker" ] || fail "policy state marker is missing or unsafe"
    [ "$(cat "$marker")" = "$(printf '%s' "$expected")" ] ||
        fail "policy state marker belongs to a different package release or image"
    python3 - "$marker" <<'PY'
import os
import stat
import sys

info = os.lstat(sys.argv[1])
if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
    raise SystemExit("policy state marker must be a single-link regular file")
if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
    raise SystemExit("policy state marker must be invoking-user-owned mode 0600")
PY
}

has_unmarked_redis_state() {
    for entry in "$STATE_DIR/state/redis"/* "$STATE_DIR/state/redis"/.[!.]* "$STATE_DIR/state/redis"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        return 0
    done
    return 1
}

write_policy_marker() {
    python3 - "$POLICY_MARKER" "$RELEASE_ID" "$IMAGE_ID" <<'PY'
import os
import sys

path, release, image_id = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as marker:
    marker.write(f"zpr-demo-policy-v1\nrelease={release}\nimage={image_id}\n".encode("ascii"))
PY
}

wait_for_redis() {
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        result=$(compose exec -T vs redis-cli --raw PING 2>/dev/null || true)
        [ "$result" = PONG ] && return 0
        attempt=$((attempt + 1))
        sleep 1
    done
    fail "persistent Visa Redis service did not become ready; stop preserves its state"
}

policy_exists() {
    result=$(compose exec -T vs redis-cli --raw EXISTS policy:current) ||
        fail "cannot inspect the persisted Visa policy state"
    result=$(printf '%s' "$result" | tr -d '\r\n')
    case "$result" in 0|1) printf '%s' "$result" ;; *) fail "Visa returned an invalid policy state" ;; esac
}

wait_for_visa_lease() {
    attempt=0
    while [ "$attempt" -lt 120 ]; do
        ttl=$(compose exec -T vs redis-cli --raw PTTL lock:vsinstance) ||
            fail "cannot inspect the Visa Service instance lease"
        case "$ttl" in
            -2) return 0 ;;
            -1) fail "Visa Service lease has no expiry; refusing to start a competing instance" ;;
            ''|*[!0-9]*) fail "Visa Service returned an invalid instance lease TTL" ;;
            *) ;;
        esac
        attempt=$((attempt + 1))
        sleep 1
    done
    fail "previous Visa Service lease did not expire; refusing a competing instance"
}

launch_session() {
    service=$1
    session=$2
    command_line=$3
    if compose exec -T "$service" tmux has-session -t "$session" >/dev/null 2>&1; then
        return 0
    fi
    compose exec -T "$service" tmux new-session -d -s "$session" -c /conf \
        "$command_line 2>&1 | tee /logs/$session.log" >/dev/null ||
        fail "could not launch $session in $service; inspect package logs under $STATE_DIR/logs"
    sleep 1
    compose exec -T "$service" tmux has-session -t "$session" >/dev/null 2>&1 ||
        fail "$session exited during startup; inspect package logs under $STATE_DIR/logs"
}

wait_for_link() {
    service=$1
    address=$2
    description=$3
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        links=$(compose exec -T "$service" /app/bin/ph-cli \
            -p /var/run/zpr/control.sock link show 2>/dev/null || true)
        if printf '%s\n' "$links" | grep -F "$address:" | grep -Fq '(Active)'; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    fail "$description did not become Active; inspect package logs under $STATE_DIR/logs"
}

nodes_synchronized() {
    for node in node0 node1; do
        # Read the credential inside the container; never place it in argv.
        # shellcheck disable=SC2016
        details=$(compose exec -T vs sh -c '
            IFS= read -r VS_API_KEY || [ -n "$VS_API_KEY" ]
            export VS_API_KEY
            exec /app/bin/vs-admin --svc-url "https://[fd5a:5052::1]:8182" \
                --ca-cert /conf/include/admin-tls-cert.pem --format compact actors --cn "$1"
        ' sh "$node.demo" < "$STATE_DIR/bob/web-monitor.key") || return 1
        printf '%s\n' "$details" | python3 -c '
import json
import sys
actor = json.load(sys.stdin)
details = actor.get("node_details") or {}
sys.exit(0 if actor.get("cn") == sys.argv[1] and actor.get("node")
         and details.get("in_sync") is True
         and details.get("pending_install") == 0
         and details.get("pending_revocation") == 0 else 1)
' "$node.demo" || return 1
    done
}

wait_for_stable_network() {
    attempt=0
    stable=0
    while [ "$attempt" -lt 60 ]; do
        attempt=$((attempt + 1))
        if nodes_synchronized &&
            compose exec -T node0 /app/bin/ph-cli -p /var/run/zpr/control.sock link show |
                grep -F '172.30.0.10:5000' | grep -Fq '(Active)' &&
            compose exec -T node1 /app/bin/ph-cli -p /var/run/zpr/control.sock link show |
                grep -F '172.30.0.13:5000' | grep -Fq '(Active)' &&
            compose exec -T alice curl --noproxy '*' -g -6 -fsS \
                --connect-timeout 2 --max-time 3 'http://[fd5a:5052:8888::8]/' >/dev/null; then
            stable=$((stable + 1))
            if [ "$stable" -ge 6 ]; then
                printf 'PASS: both nodes synchronized, peer links active and Alice HTTP stable across six readiness samples.\n'
                return
            fi
        else
            stable=0
            printf 'Waiting for synchronized nodes, active peers and stable Alice HTTP (attempt %s/60).\n' "$attempt" >&2
        fi
        sleep 2
    done
    fail "network did not stabilize; inspect node and Visa logs under $STATE_DIR/logs"
}

start_runtime() {
    validate_loaded_image
    validate_compose
    ZPR_DEMO_PACKAGE_DIR=$PACKAGE_DIR "$RUNTIME_DIR/init-demo-identities.sh" prepare "$STATE_DIR" ||
        fail "identity preparation failed; no services were started"
    validate_complete_state || fail "identity initializer did not produce a complete safe state"
    if ! python3 - "$STATE_DIR" <<'PY'
import os
from pathlib import Path
import stat
import sys

for service in ("node0", "node1", "vs", "web0", "web1", "alice"):
    path = Path(sys.argv[1]) / "conf" / service / "include"
    if not os.path.lexists(path):
        path.mkdir(mode=0o700)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700 or any(path.iterdir())):
        raise SystemExit(f"unsafe or nonempty nested identity mountpoint: {path}")
PY
    then
        fail "cannot prepare read-only identity mountpoints"
    fi

    if [ -e "$POLICY_PENDING" ] || [ -L "$POLICY_PENDING" ]; then
        expected=$(printf 'zpr-demo-policy-bootstrap-pending\nrelease=%s\nimage=%s\n' "$RELEASE_ID" "$IMAGE_ID")
        [ -f "$POLICY_PENDING" ] && [ ! -L "$POLICY_PENDING" ] &&
            [ "$(cat "$POLICY_PENDING")" = "$expected" ] ||
            fail "previous policy bootstrap was interrupted; marker is unsafe or mismatched"
        for entry in "$STATE_DIR/state/redis"/* "$STATE_DIR/state/redis"/.[!.]* "$STATE_DIR/state/redis"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            [ "$entry" = "$POLICY_PENDING" ] ||
                fail "previous policy bootstrap was interrupted with Redis data; inspect state before retrying"
        done
        containers=$(compose ps --all --quiet) || fail "cannot inspect failed-start containers"
        [ -n "$containers" ] || fail "cannot prove prior containers never started"
        count=0
        for container in $containers; do
            status=$(docker inspect --format '{{.State.Status}}' "$container") ||
                fail "cannot inspect prior container state"
            [ "$status" = created ] || fail "prior container may have run; inspect policy state before retrying"
            count=$((count + 1))
        done
        [ "$count" -eq 6 ] || fail "cannot prove all six prior containers never started"
        rm "$POLICY_PENDING" || fail "cannot clear never-started bootstrap marker"
        printf 'Recovered bootstrap marker from containers that never started; identities preserved.\n'
    fi
    if [ -e "$POLICY_MARKER" ] || [ -L "$POLICY_MARKER" ]; then
        validate_policy_marker "$POLICY_MARKER" || fail "invalid persisted policy marker"
        bootstrap_policy=no
    else
        if has_unmarked_redis_state; then
            fail "Redis contains unmarked state; refusing to replace or reset the active policy"
        fi
        printf 'zpr-demo-policy-bootstrap-pending\nrelease=%s\nimage=%s\n' \
            "$RELEASE_ID" "$IMAGE_ID" > "$POLICY_PENDING" ||
            fail "cannot record the pending policy bootstrap state"
        chmod 600 "$POLICY_PENDING" || fail "cannot protect the pending policy marker"
        bootstrap_policy=yes
    fi

    compose up --detach --no-build --pull never ||
        fail "Docker Compose could not start the package containers; persistent state is retained"
    wait_for_redis
    active_policy=$(policy_exists)
    if [ "$bootstrap_policy" = no ] && [ "$active_policy" != 1 ]; then
        fail "persisted Redis state has no active policy; refusing automatic reset"
    fi
    if [ "$active_policy" = 0 ]; then
        [ "$bootstrap_policy" = yes ] ||
            fail "active policy is missing from initialized Redis state; refusing reset"
        if ! compose exec -T vs tmux has-session -t vs >/dev/null 2>&1; then
            wait_for_visa_lease
        fi
        launch_session vs vs "/app/bin/vs multinode-demo.bin2"
    else
        if ! compose exec -T vs tmux has-session -t vs >/dev/null 2>&1; then
            wait_for_visa_lease
        fi
        launch_session vs vs "/app/bin/vs"
    fi
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        active_policy=$(policy_exists)
        [ "$active_policy" = 1 ] && break
        attempt=$((attempt + 1))
        sleep 1
    done
    [ "$active_policy" = 1 ] || fail "Visa policy did not load; pending marker retained for manual recovery"
    if [ "$bootstrap_policy" = yes ]; then
        rm "$POLICY_PENDING" || fail "cannot finalize policy bootstrap marker"
        write_policy_marker
    fi

    launch_session node0 node0 "/app/bin/ph node -c node0-conf.toml"
    launch_session node1 node1 "/app/bin/ph node -c node1-conf.toml"
    wait_for_link node0 172.30.0.10 "node0 peer link to node1"
    wait_for_link node1 172.30.0.13 "node1 peer link to node0"
    launch_session vs vs-adapter "/app/bin/ph adapter -c adapter-vs-conf.toml"
    if ! compose exec -T web0 tmux has-session -t web0-adapter >/dev/null 2>&1; then
        attempt=0
        while :; do
            links=$(compose exec -T node0 /app/bin/ph-cli \
                -p /var/run/zpr/control.sock link show) ||
                fail "cannot inspect stale web0 adapter links before registration"
            if ! printf '%s\n' "$links" | grep -Fq '172.30.0.14:'; then
                break
            fi
            [ "$attempt" -lt 60 ] ||
                fail "old web0 adapter link did not expire; refusing overlapping registration"
            attempt=$((attempt + 1))
            sleep 1
        done
    fi
    launch_session web0 web0-adapter "env ZPR_ADAPTER_SERVICES=OciWeb /app/bin/ph adapter -c adapter-web0-conf.toml"
    launch_session alice alice-adapter "/app/bin/ph adapter -c adapter-alice-conf.toml"
    wait_for_link node0 172.30.0.11 "Visa Service adapter link"
    wait_for_link node0 172.30.0.14 "web0 adapter link"
    wait_for_link node1 172.30.0.15 "Alice adapter link"
    compose exec -T web0 curl -fsS --connect-timeout 2 --max-time 5 http://localhost:80 >/dev/null ||
        fail "web0 HTTP service did not become ready; inspect package logs under $STATE_DIR/logs"
    wait_for_stable_network
    printf 'ZPR demo services started for release %s; base traffic is ready, not a complete Simulator lab.\n' "$RELEASE_ID"
}

run_smoke() {
    validate_complete_state || fail "complete initialized identity state is required"
    validate_policy_marker "$POLICY_MARKER" || fail "initialized base policy state is required"
    validate_loaded_image
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        if response=$(compose exec -T alice curl --noproxy '*' -g -6 -fsS \
            --connect-timeout 10 --max-time 15 'http://[fd5a:5052:8888::8]/'); then
            [ -n "$response" ] || fail "Alice-to-web0 ZPR request returned an empty response"
            printf 'PASS: Alice received an HTTP response from web0 across the ZPR node peer.\n'
            return
        fi
        attempt=$((attempt + 1))
    done
    printf 'Alice-to-web0 failed after three attempts. Collecting network diagnostics:\n' >&2
    for service in alice web0 node0 node1 vs; do
        printf '\n--- %s IPv6 addresses ---\n' "$service" >&2
        compose exec -T "$service" ip -6 address show >&2 ||
            printf 'Could not inspect %s IPv6 addresses.\n' "$service" >&2
        printf '\n--- %s IPv6 routes ---\n' "$service" >&2
        compose exec -T "$service" ip -6 route show table all >&2 ||
            printf 'Could not inspect %s IPv6 routes.\n' "$service" >&2
    done
    for service in node0 node1; do
        printf '\n--- %s ZPR links ---\n' "$service" >&2
        compose exec -T "$service" /app/bin/ph-cli -p /var/run/zpr/control.sock link show >&2 ||
            printf 'Could not inspect %s ZPR links.\n' "$service" >&2
    done
    for name in alice-adapter web0-adapter node0 node1 vs vs-adapter; do
        printf '\n--- %s log (last 60 lines) ---\n' "$name" >&2
        if [ -f "$STATE_DIR/logs/$name.log" ] && [ ! -L "$STATE_DIR/logs/$name.log" ]; then
            tail -n 60 "$STATE_DIR/logs/$name.log" >&2 ||
                printf 'Could not read %s log.\n' "$name" >&2
        else
            printf 'Log unavailable: %s\n' "$name" >&2
        fi
    done
    fail "Alice could not reach web0 across the ZPR node peer; network diagnostics are above"
}

case "$command_name" in
    start)
        start_runtime
        ;;
    smoke)
        validate_compose
        run_smoke
        ;;
    stop)
        compose down || fail "Docker Compose could not stop the ZPR demo"
        printf 'ZPR demo stopped; persistent identity, policy, Redis, and log state retained.\n'
        ;;
    status)
        compose ps || fail "Docker Compose could not report the ZPR demo status"
        if [ -f "$STATE_MARKER" ]; then
            printf 'Status is container-level only; application readiness is not asserted.\n'
        else
            printf 'Identity state is not initialized; no application readiness is asserted.\n'
        fi
        ;;
esac

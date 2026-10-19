#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zpr-runtime-test.XXXXXX")
TEMP_ROOT=$(CDPATH='' cd -- "$TEMP_ROOT" && pwd -P)
trap 'rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "expected output to contain: $2" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "unexpected output contained: $2" ;;
        *) ;;
    esac
}

RELEASE_ID=runtime-test-1
PACKAGE_DIR=$TEMP_ROOT/install/$RELEASE_ID/zpr-demo
STATE_DIR=$TEMP_ROOT/state/zpr-demo
RUNTIME_DIR=$PACKAGE_DIR/runtime
FAKE_BIN=$TEMP_ROOT/bin
FAKE_DOCKER_LOG=$TEMP_ROOT/docker.log
FAKE_INIT_LOG=$TEMP_ROOT/initializer.log
FAKE_SESSIONS=$TEMP_ROOT/sessions
FAKE_POLICY_FILE=$TEMP_ROOT/policy-loaded
FAKE_RUNNING=$TEMP_ROOT/running
IMAGE_ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IMAGE_REFERENCE=zpr-multinode:runtime-test-1

mkdir -p "$RUNTIME_DIR/assets/entrypoints" "$RUNTIME_DIR/assets/tools" "$FAKE_BIN" "$TEMP_ROOT/state"
cp "$SCRIPT_DIR/zpr-demo-runtime.sh" "$RUNTIME_DIR/zpr-demo-runtime.sh"
cp "$SCRIPT_DIR/zpr-demo-compose.yml" "$RUNTIME_DIR/zpr-demo-compose.yml"
printf '%s\n' "$IMAGE_REFERENCE" > "$RUNTIME_DIR/image-reference"
: > "$FAKE_DOCKER_LOG"
: > "$FAKE_SESSIONS"
for asset in \
    entrypoint-alice.sh entrypoint-node0.sh entrypoint-node1.sh \
    entrypoint-vs.sh entrypoint-web0.sh entrypoint-web1.sh; do
    printf '#!/bin/sh\nexit 0\n' > "$RUNTIME_DIR/assets/entrypoints/$asset"
    chmod 755 "$RUNTIME_DIR/assets/entrypoints/$asset"
done
printf '#!/bin/sh\nexit 0\n' > "$RUNTIME_DIR/assets/tools/regen-banner.sh"
chmod 755 "$RUNTIME_DIR/assets/tools/regen-banner.sh"
cat > "$RUNTIME_DIR/init-demo-identities.sh" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 2 ] && [ "$1" = prepare ] || exit 2
printf '%s\n' "$2" >> "$FAKE_INIT_LOG"
if [ "${FAKE_INIT_FAIL:-0}" = 1 ]; then
    echo "mock identity preparation failure" >&2
    exit 1
fi
mkdir -p "$2/include" "$2/conf/node0" "$2/conf/node1" "$2/conf/vs" \
    "$2/conf/web0" "$2/conf/web1" "$2/conf/alice" "$2/bob" "$2/admin" \
    "$2/state/redis" "$2/logs"
find "$2" -type d -exec chmod 700 {} \;
printf 'mock complete identity state\n' > "$2/.zpr-demo-state-v1"
chmod 600 "$2/.zpr-demo-state-v1"
EOF
chmod 755 "$RUNTIME_DIR/init-demo-identities.sh"
cat > "$PACKAGE_DIR/manifest.json" <<EOF
{
  "schema": "zpr.demo.runtime-package.v2",
  "status": "demo-unqualified-runtime-package",
  "release_id": "$RELEASE_ID",
  "platform": "linux/amd64",
  "package_id": "zpr-demo-image",
  "required_peer_package_id": "simulator-image",
  "component": {
    "id": "zpr-demo-image",
    "image_reference": "$IMAGE_REFERENCE",
    "image_id": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    "docker_image_id": "$IMAGE_ID"
  }
}
EOF

cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"

if [ "$1" = inspect ]; then
    printf '%s\n' "${FAKE_CONTAINER_STATUS:-created}"
    exit 0
fi
if [ "$1" = image ]; then
    [ "$2" = inspect ] || exit 2
    printf '%s|linux|amd64\n' "${FAKE_IMAGE_ID:-$IMAGE_ID}"
    exit 0
fi
[ "$1" = compose ] || exit 2
shift
while [ "$#" -gt 0 ]; do
    case "$1" in
        --project-name|--project-directory|--file)
            [ "$#" -ge 2 ] || exit 2
            shift 2
            ;;
        *) break ;;
    esac
done
[ "$#" -gt 0 ] || exit 2
action=$1
shift
case "$action" in
    version)
        printf 'Docker Compose version v2.30.0\n'
        ;;
    config)
        [ "$1" = --quiet ] || exit 2
        ;;
    up)
        [ "$1" = --detach ] && [ "$2" = --no-build ] && [ "$3" = --pull ] && [ "$4" = never ] ||
            { echo "unsafe compose up arguments" >&2; exit 2; }
        : > "$FAKE_RUNNING"
        ;;
    ps)
        if [ "${1:-}" = --all ]; then
            printf '%s\n' node0 node1 vs web0 web1 alice
            exit 0
        fi
        if [ -f "$FAKE_RUNNING" ]; then
            printf 'NAME                 STATUS\nzprdemo-node0         running\n'
        fi
        ;;
    down)
        rm -f "$FAKE_RUNNING"
        : > "$FAKE_SESSIONS"
        ;;
    exec)
        [ "$1" = -T ] || exit 2
        shift
        service=$1
        shift
        tool=$1
        shift
        case "$tool" in
            redis-cli)
                [ "$1" = --raw ] || exit 2
                shift
                case "$1" in
                    PING) printf 'PONG\n' ;;
                    EXISTS)
                        if [ -f "$FAKE_POLICY_FILE" ]; then printf '1\n'; else printf '0\n'; fi
                        ;;
                    PTTL) printf '%s\n' "${FAKE_LEASE_TTL:--2}" ;;
                    *) exit 2 ;;
                esac
                ;;
            tmux)
                case "$1" in
                    has-session)
                        [ "$2" = -t ] || exit 2
                        grep -Fxq "$3" "$FAKE_SESSIONS"
                        ;;
                    new-session)
                        [ "$2" = -d ] && [ "$3" = -s ] && [ "$5" = -c ] && [ "$6" = /conf ] ||
                            { echo "unexpected tmux arguments" >&2; exit 2; }
                        printf '%s\n' "$4" >> "$FAKE_SESSIONS"
                        case "$4:$7" in
                            vs:*multinode-demo.bin2*) : > "$FAKE_POLICY_FILE" ;;
                        esac
                        ;;
                    *) exit 2 ;;
                esac
                ;;
            /app/bin/ph-cli)
                case "$service" in
                    node0)
                        printf '172.30.0.10:5000 (Active)\n172.30.0.11:5000 (Active)\n'
                        if grep -Fxq web0-adapter "$FAKE_SESSIONS"; then
                            printf '172.30.0.14:5000 (Active)\n'
                        fi
                        ;;
                    node1)
                        printf '172.30.0.13:5000 (Active)\n172.30.0.15:5000 (Active)\n'
                        ;;
                    *) exit 2 ;;
                esac
                ;;
            curl)
                case "$service" in
                    web0) printf 'local web0 response\n' ;;
                    alice)
                        [ "${FAKE_SMOKE_FAIL:-0}" != 1 ] || exit 28
                        printf 'ZPR OCIWEB response\n' ;;
                    *) exit 2 ;;
                esac
                ;;
            ip) printf 'mock IPv6 network diagnostic\n' ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF
chmod 755 "$FAKE_BIN/docker"
cat > "$FAKE_BIN/id" <<'EOF'
#!/bin/sh
case "$1" in
    -u) printf '%s\n' "${FAKE_UID:-0}" ;;
    *) /usr/bin/id "$@" ;;
esac
EOF
chmod 755 "$FAKE_BIN/id"
export FAKE_DOCKER_LOG FAKE_INIT_LOG FAKE_SESSIONS FAKE_POLICY_FILE FAKE_RUNNING IMAGE_ID

run_runtime() {
    ZPR_DEMO_PACKAGE_DIR=$PACKAGE_DIR \
        ZPR_DEMO_STATE_DIR=$STATE_DIR \
        PATH=$FAKE_BIN:$PATH \
        "$RUNTIME_DIR/zpr-demo-runtime.sh" "$@"
}

for action in start stop status smoke; do
    if output=$(FAKE_UID=1000 run_runtime "$action" 2>&1); then
        fail "$action accepted non-root access to root-owned demo state"
    fi
    assert_contains "$output" "all runtime commands require sudo"
done
[ ! -e "$FAKE_INIT_LOG" ] || fail "non-root start reached identity generation"
if [ -s "$FAKE_DOCKER_LOG" ]; then
    fail "non-root lifecycle command reached Docker"
fi
if output=$(FAKE_LEASE_TTL=-- run_runtime start 2>&1); then
    fail "start accepted a malformed Visa Service lease TTL"
fi
assert_contains "$output" "invalid instance lease TTL"
[ -f "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending" ] ||
    fail "failed lease validation did not retain the pending policy marker"
output=$(run_runtime start 2>&1) || fail "start failed: $output"
assert_contains "$output" "ZPR demo services started"
[ -f "$STATE_DIR/.zpr-demo-state-v1" ] || fail "initializer did not prepare identity state"
[ -f "$STATE_DIR/state/redis/.zpr-demo-policy-v1" ] || fail "base policy marker was not finalized"
[ ! -e "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending" ] ||
    fail "pending policy marker was not removed after policy load"
grep -Fxq vs "$FAKE_SESSIONS" || fail "Visa Service process was not launched"
grep -Fxq node0 "$FAKE_SESSIONS" || fail "node0 process was not launched"
grep -Fxq node1 "$FAKE_SESSIONS" || fail "node1 process was not launched"
grep -Fxq web0-adapter "$FAKE_SESSIONS" || fail "web0 adapter was not launched"
grep -Fxq alice-adapter "$FAKE_SESSIONS" || fail "Alice adapter was not launched"
if grep -Fq web1-adapter "$FAKE_SESSIONS"; then
    fail "runtime unexpectedly enabled the optional web1 adapter"
fi
grep -Fq 'compose' "$FAKE_DOCKER_LOG" || fail "runtime did not use Docker Compose"
grep -Fq 'up --detach --no-build --pull never' "$FAKE_DOCKER_LOG" ||
    fail "runtime did not disable builds and pulls"

output=$(run_runtime smoke 2>&1) || fail "smoke failed: $output"
assert_contains "$output" "PASS: Alice received an HTTP response from web0"
before=$(grep -c 'alice curl' "$FAKE_DOCKER_LOG")
if output=$(FAKE_SMOKE_FAIL=1 run_runtime smoke 2>&1); then
    fail "smoke accepted failed Alice HTTP requests"
fi
after=$(grep -c 'alice curl' "$FAKE_DOCKER_LOG")
[ "$((after - before))" -eq 3 ] || fail "smoke did not make three bounded attempts"
assert_contains "$output" "mock IPv6 network diagnostic"
assert_contains "$output" "Alice could not reach web0"
assert_contains "$output" "alice-adapter log"

output=$(run_runtime status 2>&1) || fail "status failed: $output"
assert_contains "$output" "container-level only"
assert_not_contains "$output" "application readiness is asserted"

output=$(run_runtime stop 2>&1) || fail "stop failed: $output"
assert_contains "$output" "persistent identity, policy, Redis, and log state retained"
[ -f "$STATE_DIR/state/redis/.zpr-demo-policy-v1" ] || fail "stop removed policy state"
if grep -F 'down --volumes' "$FAKE_DOCKER_LOG"; then
    fail "stop removed persistent volumes"
fi

output=$(run_runtime start 2>&1) || fail "restart failed: $output"
vs_policy_bootstraps=$(grep -c 'multinode-demo.bin2' "$FAKE_DOCKER_LOG" || true)
[ "$vs_policy_bootstraps" -eq 1 ] || fail "restart attempted to reinitialize the persisted policy"
output=$(run_runtime stop 2>&1) || fail "second stop failed: $output"

printf 'interrupted\n' > "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending"
chmod 600 "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending"
up_count_before=$(grep -c 'up --detach --no-build --pull never' "$FAKE_DOCKER_LOG")
if output=$(run_runtime start 2>&1); then
    fail "start accepted an interrupted policy bootstrap"
fi
assert_contains "$output" "previous policy bootstrap was interrupted"
up_count_after=$(grep -c 'up --detach --no-build --pull never' "$FAKE_DOCKER_LOG")
[ "$up_count_before" -eq "$up_count_after" ] || fail "interrupted state reached Docker Compose"
rm "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending"

rm "$STATE_DIR/state/redis/.zpr-demo-policy-v1"
printf 'zpr-demo-policy-bootstrap-pending\nrelease=%s\nimage=%s\n' "$RELEASE_ID" "$IMAGE_ID" \
    > "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending"
chmod 600 "$STATE_DIR/state/redis/.zpr-demo-policy-bootstrap-pending"
if output=$(FAKE_CONTAINER_STATUS=exited run_runtime start 2>&1); then
    fail "recovered bootstrap after a container may have run"
fi
assert_contains "$output" "prior container may have run"
output=$(run_runtime start 2>&1) || fail "never-started recovery failed: $output"
assert_contains "$output" "Recovered bootstrap marker"
for service in node0 node1 vs web0 web1 alice; do
    [ -d "$STATE_DIR/conf/$service/include" ] || fail "missing nested mountpoint: $service"
done
output=$(run_runtime stop 2>&1) || fail "recovery stop failed: $output"

init_count_before=$(wc -l < "$FAKE_INIT_LOG" | tr -d ' ')
if output=$(FAKE_IMAGE_ID=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run_runtime start 2>&1); then
    fail "start accepted a different locally loaded image"
fi
assert_contains "$output" "does not match the package's pinned"
init_count_after=$(wc -l < "$FAKE_INIT_LOG" | tr -d ' ')
[ "$init_count_before" -eq "$init_count_after" ] || fail "identity initializer ran before image validation"

printf 'wrong-reference\n' > "$RUNTIME_DIR/image-reference"
if output=$(run_runtime status 2>&1); then
    fail "status accepted a package image-reference mismatch"
fi
assert_contains "$output" "manifest, release directory, or image-reference"

if ! grep -Fq '/include:/conf/include:ro' "$SCRIPT_DIR/zpr-demo-compose.yml"; then
    fail "Compose does not mount the shared identity include directory read-only"
fi
if grep -Eq '^[[:space:]]+build:' "$SCRIPT_DIR/zpr-demo-compose.yml"; then
    fail "Compose contains a build directive"
fi

printf 'PASS: source-independent ZPR start/stop/status/smoke, policy preservation, image pinning, and no-build/no-pull orchestration (Docker mocked).\n'

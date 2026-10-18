#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/zpr-demo-host-preflight.XXXXXX")
trap 'rm -f "$temporary/preflight-demo-host.sh" "$temporary/os-release" "$temporary/output" "$temporary/calls" "$temporary/bin/uname" "$temporary/bin/docker"; rmdir "$temporary/bin" "$temporary"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$temporary/bin"
sed -e "s|/etc/os-release|$temporary/os-release|g" \
    -e 's|/dev/net/tun|/dev/null|g' \
    "$script_dir/preflight-demo-host.sh" > "$temporary/preflight-demo-host.sh"

cat > "$temporary/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) printf '%s\n' "$TEST_KERNEL" ;;
    -m) printf '%s\n' "$TEST_ARCH" ;;
    *) exit 90 ;;
esac
EOF
cat > "$temporary/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_CALLS"
case "$*" in
    "context inspect --format {{.Endpoints.docker.Host}}"|"context inspect local --format {{.Endpoints.docker.Host}}")
        printf '%s\n' "$TEST_ENDPOINT" ;;
    "info --format {{.OSType}} {{.Architecture}} {{.ServerVersion}}")
        printf '%s\n' "$TEST_ENGINE" ;;
    "version --format {{.Client.Version}}")
        printf '%s\n' "$TEST_CLIENT_VERSION" ;;
    "compose version --short")
        printf '%s\n' "$TEST_COMPOSE" ;;
    *) echo "Unexpected Docker operation" >&2; exit 90 ;;
esac
EOF
chmod 700 "$temporary/bin/uname" "$temporary/bin/docker"
export TEST_CALLS="$temporary/calls"
export TEST_KERNEL TEST_ARCH TEST_ENDPOINT TEST_ENGINE TEST_CLIENT_VERSION TEST_COMPOSE
unset DOCKER_HOST DOCKER_CONTEXT

reset_case() {
    TEST_KERNEL=Linux
    TEST_ARCH=x86_64
    TEST_ENDPOINT=unix:///var/run/docker.sock
    TEST_ENGINE='linux x86_64 29.0.0'
    TEST_CLIENT_VERSION=29.0.0
    TEST_COMPOSE=v2.40.0
    printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$temporary/os-release"
    : > "$temporary/calls"
    unset DOCKER_HOST DOCKER_CONTEXT
}

check() {
    expected=$1
    message=$2
    shift 2
    status=0
    PATH="$temporary/bin:/usr/bin:/bin" /bin/sh "$temporary/preflight-demo-host.sh" "$@" \
        > "$temporary/output" 2>&1 || status=$?
    if [ "$status" -ne "$expected" ] || ! grep -F "$message" "$temporary/output" >/dev/null; then
        cat "$temporary/output"
        echo "Unexpected status $status (wanted $expected) or missing diagnostic: $message" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$message"
}

reset_case
check 0 "Host checks passed"
reset_case
TEST_KERNEL=Darwin
check 1 "must run Linux"
reset_case
TEST_ARCH=aarch64
check 1 "must be x86-64"
reset_case
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$temporary/os-release"
check 1 "Ubuntu 26.04 LTS"
reset_case
printf 'ID=debian\nVERSION_ID="13"\n' > "$temporary/os-release"
check 1 "Ubuntu 26.04 LTS"
reset_case
TEST_ENDPOINT=ssh://remote
check 1 "local Docker Engine"
! grep '^info ' "$temporary/calls"
reset_case
TEST_ENGINE='linux arm64 29.0.0'
check 1 "Docker Engine must be x86-64"
reset_case
TEST_ENGINE='windows amd64 29.0.0'
check 1 "must report Linux"
reset_case
TEST_COMPOSE=1.29.0
check 1 "Docker Compose v2"
reset_case
export DOCKER_HOST=tcp://remote:2375 DOCKER_CONTEXT=local
check 0 "Host checks passed"
grep '^context inspect local ' "$temporary/calls" >/dev/null
reset_case
check 2 "usage:" unexpected

echo "All host preflight cases passed with command stubs; no Docker daemon or host state was changed."

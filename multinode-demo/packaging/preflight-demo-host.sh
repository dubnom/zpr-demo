#!/bin/sh
set -eu

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if [ "$#" -ne 0 ]; then
    echo "usage: sh preflight-demo-host.sh" >&2
    exit 2
fi

[ "$(uname -s)" = Linux ] || fail "The demo host must run Linux."
[ "$(uname -m)" = x86_64 ] || fail "The demo host must be x86-64."
[ -r /etc/os-release ] || fail "Cannot read /etc/os-release."

os_id=
os_version=
while IFS='=' read -r name value; do
    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    case "$name" in
        ID) os_id=$value ;;
        VERSION_ID) os_version=$value ;;
    esac
done < /etc/os-release
[ "$os_id" = ubuntu ] && [ "$os_version" = 26.04 ] ||
    fail "The demo host must be Ubuntu 26.04 LTS (user target: 26.04.1)."
echo "PASS: Ubuntu 26.04 LTS x86-64 host."

[ -c /dev/net/tun ] || fail "/dev/net/tun is unavailable; enable TUN support before demo startup."
[ -r /dev/net/tun ] && [ -w /dev/net/tun ] ||
    fail "/dev/net/tun is not readable and writable by this account; check host permissions."
echo "PASS: /dev/net/tun character device is accessible (container TUN behavior remains to be tested)."

command -v docker >/dev/null 2>&1 ||
    fail "Docker CLI is missing; install Docker Engine and Compose v2."

if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}') ||
        fail "Cannot inspect the selected Docker context."
elif [ -n "${DOCKER_HOST:-}" ]; then
    endpoint=$DOCKER_HOST
else
    endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}') ||
        fail "Cannot inspect the current Docker context."
fi
case "$endpoint" in
    unix:///*) ;;
    *) fail "The demo requires a local Docker Engine on a Unix socket." ;;
esac

engine=$(docker info --format '{{.OSType}} {{.Architecture}} {{.ServerVersion}}') ||
    fail "Cannot query Docker Engine; check daemon availability and socket permissions."
engine_os=
engine_arch=
engine_version=
extra=
IFS=' ' read -r engine_os engine_arch engine_version extra <<EOF
$engine
EOF
[ "$engine_os" = linux ] && [ -n "$engine_version" ] && [ -z "$extra" ] ||
    fail "Docker Engine must report Linux and a server version."
case "$engine_arch" in
    amd64|x86_64) ;;
    *) fail "Docker Engine must be x86-64 (amd64), not emulated or another architecture." ;;
esac
client_version=$(docker version --format '{{.Client.Version}}') ||
    fail "Cannot query Docker CLI version."
printf 'PASS: Local Linux/amd64 Docker Engine %s; Docker CLI %s.\n' \
    "$engine_version" "$client_version"

compose=$(docker compose version --short) ||
    fail "Docker Compose v2 is unavailable."
case "$compose" in
    2.*|v2.*) ;;
    *) fail "Docker Compose v2 is required." ;;
esac
printf 'PASS: Docker Compose %s.\n' "$compose"

if [ -r /proc/meminfo ]; then
    memory_kib=$(awk '$1 == "MemTotal:" { print $2; exit }' /proc/meminfo)
    case "$memory_kib" in
        ''|*[!0-9]*) echo "INFO: Could not determine host memory." ;;
        *) awk -v kib="$memory_kib" 'BEGIN { printf "INFO: Host memory: %.1f GiB.\n", kib / 1048576 }' ;;
    esac
fi
disk_kib=$(df -Pk / | awk 'NR == 2 { print $4 }')
case "$disk_kib" in
    ''|*[!0-9]*) echo "INFO: Could not determine free space on /." ;;
    *) awk -v kib="$disk_kib" 'BEGIN { printf "INFO: Free space on /: %.1f GiB.\n", kib / 1048576 }' ;;
esac

echo "Host checks passed; record these versions and resource values with the demo results."
echo "This is a host preflight only, not package installation, container-TUN validation, or release qualification."

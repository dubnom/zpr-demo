#!/bin/sh
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
multi_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd)
docs_root=$(CDPATH='' cd -- "$multi_dir/../.." && pwd)
dashboard_dir=${ZPR_DASHBOARD_DIR:-$docs_root/zpr-visaservice/zpr-dashboard}
: "${ZPR_RUNTIME_ROOT:?organization runtime root required}"
: "${ZPR_CONTAINER_PREFIX:?organization container prefix required}"
: "${ZPR_NETWORK_NAME:?organization network required}"
registry=${ZPR_PROVIDER_MANAGER_URLS_FILE:-$docs_root/.local-runtime/dashboard-stack/provider-managers.json}
. "$dashboard_dir/scripts/provider-managers.sh"
provider_manager_urls "$registry" >/dev/null

directory_sources=$(awk '
    /^\[trusted_service_http\./ {
        source=$0
        sub(/^\[trusted_service_http\./, "", source)
        sub(/\]$/, "", source)
        next
    }
    /^\[/ { source="" }
    /^url = "https:\/\/directory:8443"$/ && source != "" { print source }
' "$ZPR_RUNTIME_ROOT/conf/vs/vs.toml")
[ -n "$directory_sources" ] || { echo "No trusted source targets the organization directory" >&2; exit 1; }
ZPR_DIRECTORY_BASE_DN=$(docker inspect "${ZPR_CONTAINER_PREFIX}directory" \
    --format '{{json .Config.Env}}' | jq -er '.[] | select(startswith("ZPR_DIRECTORY_BASE_DN=")) | ltrimstr("ZPR_DIRECTORY_BASE_DN=") | select(length > 0)')
export ZPR_DIRECTORY_BASE_DN
export ZPR_TRUSTED_SERVICE_BINARY=${ZPR_TRUSTED_SERVICE_BINARY:-$docs_root/.local-runtime/dashboard-stack/zpr-trusted-service-linux-amd64}
docker build --platform linux/amd64 -t zpr-multinode-directory-manager \
    -f "$multi_dir/Dockerfile.directory-manager" "$multi_dir"
docker compose --project-name "zpr-${ZPR_CONTAINER_PREFIX%-}" \
    -f "$multi_dir/docker-compose.yml" --profile directory-manager \
    up -d --no-deps directory-manager
manager_port=$(docker inspect "${ZPR_CONTAINER_PREFIX}directory-manager" \
    --format '{{json .NetworkSettings.Ports}}' | jq -er '."8080/tcp"[0] | select(.HostIp == "127.0.0.1") | .HostPort')
manager_url="http://127.0.0.1:$manager_port/"
manager_ready=no
for attempt in $(seq 30); do
    if docker exec "${ZPR_CONTAINER_PREFIX}directory-manager" \
        curl -fsS --max-time 5 http://127.0.0.1:8080/ >/dev/null; then
        manager_ready=yes
        break
    fi
    sleep 1
done
if [ "$manager_ready" != yes ]; then
    docker logs "${ZPR_CONTAINER_PREFIX}directory-manager" >&2
    echo "Directory manager did not become ready; no URL registered" >&2
    exit 1
fi
register_provider_managers "$registry" "$directory_sources" "$manager_url"
printf 'Registered directory manager for %s at %s\n' "$directory_sources" "$manager_url"

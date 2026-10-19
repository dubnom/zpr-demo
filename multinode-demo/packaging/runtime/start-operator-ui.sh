#!/usr/bin/env bash
set -euo pipefail
umask 077

action=${1:-start}
case "$action" in start|stop|status) ;; *) printf 'usage: start-operator-ui.sh start|stop|status\n' >&2; exit 2 ;; esac
[ "$#" -le 1 ] || exit 2
: "${ZPR_OPERATOR_STATE_DIR:?set a private absolute operator state directory}"
: "${ZPR_OPERATOR_IMAGE:?set the pinned ZPR Docker image ID}"
: "${ZPR_VS_CONTAINER:?set the running Visa Service container name}"
: "${ZPR_VS_MONITOR_KEY_FILE:?set the absolute installed read-only monitor key path}"

fail() { printf 'zpr-operator: %s\n' "$*" >&2; exit 1; }
[[ "$ZPR_OPERATOR_IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "immutable image ID required"
[[ "$ZPR_OPERATOR_STATE_DIR" = /* && "$ZPR_VS_MONITOR_KEY_FILE" = /* ]] ||
    fail "absolute state and monitor-key paths required"
python3 - "$ZPR_OPERATOR_STATE_DIR" <<'PY'
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
if root != Path(os.path.normpath(root)) or root == Path("/"):
    raise SystemExit("unsafe operator state path")
for path in [*reversed(root.parents), root]:
    if not os.path.lexists(path):
        if path != root:
            raise SystemExit(f"missing operator state ancestor: {path}")
        path.mkdir(mode=0o700)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid())
            or info.st_mode & 0o022):
        raise SystemExit(f"unsafe operator state ancestor: {path}")
if root.stat().st_uid != os.geteuid() or root.stat().st_mode & 0o077:
    raise SystemExit("operator state must be invoking-user-owned and private")
for path in root.iterdir():
    info = path.lstat()
    if path.name in ("policy-store", "policy-compiler"):
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid()
                or info.st_mode & 0o077):
            raise SystemExit(f"unsafe operator policy store: {path}")
        if path.name == "policy-compiler":
            for child in path.rglob("*"):
                child_info = child.lstat()
                if (not (stat.S_ISDIR(child_info.st_mode) or stat.S_ISREG(child_info.st_mode))
                        or child_info.st_uid != os.geteuid() or child_info.st_mode & 0o077
                        or (stat.S_ISREG(child_info.st_mode) and child_info.st_nlink != 1)):
                    raise SystemExit(f"unsafe compiler snapshot: {child}")
        continue
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
            or info.st_nlink != 1 or info.st_mode & 0o077):
        raise SystemExit(f"unsafe operator credential: {path}")
PY
state=$ZPR_OPERATOR_STATE_DIR
existing=()
for name in zpr-operator-policy zpr-operator-service zpr-operator-room; do
    names=$(docker container ls --all --filter "name=^/$name$" --format '{{.Names}}') ||
        fail "cannot list operator containers"
    [ -n "$names" ] || continue
    [ "$names" = "$name" ] || fail "unexpected operator container lookup"
    metadata=$(docker inspect --format '{{.Image}}|{{.HostConfig.NetworkMode}}|{{index .Config.Labels "zpr.operator.state"}}|{{.Config.User}}' "$name") ||
        fail "cannot inspect $name"
    [ "$metadata" = "$ZPR_OPERATOR_IMAGE|host|$state|$(id -u):$(id -g)" ] ||
        fail "$name is not managed by this operator installation; refusing to change it"
    existing+=("$name")
done
if [ "$action" = stop ]; then
    if [ "${#existing[@]}" -gt 0 ]; then docker stop --timeout 10 "${existing[@]}" >/dev/null; fi
    printf 'Operator services stopped; credentials and ZPR state retained.\n'
    exit 0
fi
if [ "$action" = status ]; then
    for name in "${existing[@]}"; do docker inspect --format '{{.Name}}: {{.State.Status}}' "$name"; done
    if [ "${#existing[@]}" -eq 0 ]; then printf 'Operator services not installed.\n'; fi
    exit 0
fi
if [ ! -f "$state/ca.crt" ]; then
    [ -z "$(ls -A "$state")" ] || fail "partial credentials exist; inspect rather than rotate"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=ZPR operator local CA' \
        -keyout "$state/ca.key" -out "$state/ca.crt" >/dev/null 2>"$state/pki.log"
    for role in service room; do
        openssl req -newkey rsa:2048 -nodes -subj "/CN=zpr-operator-$role" \
            -keyout "$state/$role.key" -out "$state/$role.csr" >>"$state/pki.log" 2>&1
        if [ "$role" = service ]; then
            printf 'subjectAltName=IP:127.0.0.1,DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$state/extensions"
        else
            printf 'extendedKeyUsage=clientAuth\n' > "$state/extensions"
        fi
        openssl x509 -req -in "$state/$role.csr" -CA "$state/ca.crt" -CAkey "$state/ca.key" \
            -CAcreateserial -days 30 -extfile "$state/extensions" -out "$state/$role.crt" >>"$state/pki.log" 2>&1
    done
fi
for role in service room; do
    openssl verify -CAfile "$state/ca.crt" "$state/$role.crt"
done
if [ ! -d "$state/policy-store" ]; then mkdir -m 700 "$state/policy-store"; fi
docker exec "$ZPR_VS_CONTAINER" cat /conf/include/admin-tls-cert.pem > "$state/admin-ca.crt"
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,source=$ZPR_VS_MONITOR_KEY_FILE,target=/monitor.key,readonly" \
    --entrypoint /bin/cat "$ZPR_OPERATOR_IMAGE" /monitor.key > "$state/monitor.key"
[ -s "$state/monitor.key" ] || fail "monitor API key is empty"

compiler="$state/policy-compiler"
for directory in "$compiler" "$compiler/admin" "$compiler/include"; do
    if [ ! -d "$directory" ]; then mkdir -m 700 "$directory"; fi
done
identity_root=$(dirname "$(dirname "$ZPR_VS_MONITOR_KEY_FILE")")
docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges \
    --mount "type=bind,source=$identity_root/admin/multinode-demo.zplc,target=/compiler.toml,readonly" \
    --entrypoint /bin/cat "$ZPR_OPERATOR_IMAGE" /compiler.toml > "$compiler/admin/config.toml"
[ -s "$compiler/admin/config.toml" ] || fail "installed compiler configuration is empty"
for identity in node0 node1 vs web0 web1 bob alice; do
    docker exec "$ZPR_VS_CONTAINER" cat "/conf/include/$identity-public-key.pem" \
        > "$compiler/include/$identity-public-key.pem"
    [ -s "$compiler/include/$identity-public-key.pem" ] || fail "missing public bootstrap key: $identity"
done
if printf '%s\n' "${existing[@]}" | grep -Fxq zpr-operator-policy; then
    environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' zpr-operator-policy) ||
        fail "cannot inspect Policy-Service compiler configuration"
    if ! printf '%s\n' "$environment" | grep -Fxq 'ZPR_POLICY_CONFIG_FILE=/compiler/admin/config.toml'; then
        docker stop --timeout 10 zpr-operator-policy >/dev/null
        docker rm zpr-operator-policy >/dev/null
        existing=("${existing[@]/zpr-operator-policy/}")
    fi
fi
if ! printf '%s\n' "${existing[@]}" | grep -Fxq zpr-operator-policy; then
docker run -d --name zpr-operator-policy --restart unless-stopped \
    --label "zpr.operator.state=$state" \
    --network host --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,noexec,nosuid \
    --mount "type=bind,source=$state/service.crt,target=/operator/service.crt,readonly" \
    --mount "type=bind,source=$state/service.key,target=/operator/service.key,readonly" \
    --mount "type=bind,source=$state/ca.crt,target=/operator/ca.crt,readonly" \
    --mount "type=bind,source=$state/policy-store,target=/policy" \
    --mount "type=bind,source=$compiler,target=/compiler,readonly" \
    -e ZPR_POLICY_SERVICE_LISTEN=127.0.0.1:8789 \
    -e ZPR_POLICY_SERVICE_CERT_FILE=/operator/service.crt \
    -e ZPR_POLICY_SERVICE_KEY_FILE=/operator/service.key \
    -e ZPR_POLICY_SERVICE_CLIENT_CA_FILE=/operator/ca.crt \
    -e ZPR_POLICY_DB_FILE=/policy/records.db \
    -e ZPR_POLICY_CONFIG_FILE=/compiler/admin/config.toml \
    -e ZPR_ZPLC_BIN=/app/bin/zplc \
    -e ZPR_POLICY_ORGANIZATION_ID=local \
    -e ZPR_POLICY_ORGANIZATION_NAME='Local organization' \
    --entrypoint /app/bin/zpr-web-dashboard "$ZPR_OPERATOR_IMAGE" -mode policy-service
else
    docker start zpr-operator-policy >/dev/null
fi
if printf '%s\n' "${existing[@]}" | grep -Fxq zpr-operator-service; then
    environment=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' zpr-operator-service) ||
        fail "cannot inspect Control-Service policy configuration"
    if ! printf '%s\n' "$environment" | grep -Fxq 'ZPR_POLICY_SERVICE_URL=https://127.0.0.1:8789'; then
        docker stop --timeout 10 zpr-operator-service >/dev/null
        docker rm zpr-operator-service >/dev/null
        # Only the verified managed service is recreated; credentials and databases persist.
        existing=("${existing[@]/zpr-operator-service/}")
    fi
fi
if ! printf '%s\n' "${existing[@]}" | grep -Fxq zpr-operator-service; then
docker run -d --name zpr-operator-service --restart unless-stopped \
    --label "zpr.operator.state=$state" \
    --network host --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,noexec,nosuid \
    --mount "type=bind,source=$state/service.crt,target=/operator/service.crt,readonly" \
    --mount "type=bind,source=$state/service.key,target=/operator/service.key,readonly" \
    --mount "type=bind,source=$state/ca.crt,target=/operator/ca.crt,readonly" \
    --mount "type=bind,source=$state/admin-ca.crt,target=/operator/admin-ca.crt,readonly" \
    --mount "type=bind,source=$state/monitor.key,target=/operator/monitor.key,readonly" \
    --mount "type=bind,source=$state/room.crt,target=/operator/policy-client.crt,readonly" \
    --mount "type=bind,source=$state/room.key,target=/operator/policy-client.key,readonly" \
    -e ZPR_CONTROL_SERVICE_LISTEN=127.0.0.1:8790 \
    -e ZPR_CONTROL_SERVICE_CERT_FILE=/operator/service.crt \
    -e ZPR_CONTROL_SERVICE_KEY_FILE=/operator/service.key \
    -e ZPR_CONTROL_SERVICE_CLIENT_CA_FILE=/operator/ca.crt \
    -e ZPR_ADMIN_URL=https://127.0.0.1:8185 \
    -e ZPR_ADMIN_SERVER_NAME=vs.zpr \
    -e ZPR_ADMIN_CA_FILE=/operator/admin-ca.crt \
    -e ZPR_ADMIN_KEY_FILE=/operator/monitor.key \
    -e ZPR_POLICY_SERVICE_URL=https://127.0.0.1:8789 \
    -e ZPR_POLICY_CLIENT_CERT_FILE=/operator/policy-client.crt \
    -e ZPR_POLICY_CLIENT_KEY_FILE=/operator/policy-client.key \
    -e ZPR_POLICY_SERVICE_CA_FILE=/operator/ca.crt \
    --entrypoint /app/bin/zpr-web-dashboard "$ZPR_OPERATOR_IMAGE" -mode control-service
else
    docker start zpr-operator-service >/dev/null
fi
if ! printf '%s\n' "${existing[@]}" | grep -Fxq zpr-operator-room; then
docker run -d --name zpr-operator-room --restart unless-stopped \
    --label "zpr.operator.state=$state" \
    --network host --read-only --cap-drop ALL --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" --tmpfs /tmp:rw,noexec,nosuid \
    --mount "type=bind,source=$state/room.crt,target=/operator/room.crt,readonly" \
    --mount "type=bind,source=$state/room.key,target=/operator/room.key,readonly" \
    --mount "type=bind,source=$state/ca.crt,target=/operator/ca.crt,readonly" \
    -e ZPR_CONTROL_SERVICE_URL=https://127.0.0.1:8790 \
    -e ZPR_CONTROL_CLIENT_CERT_FILE=/operator/room.crt \
    -e ZPR_CONTROL_CLIENT_KEY_FILE=/operator/room.key \
    -e ZPR_CONTROL_SERVICE_CA_FILE=/operator/ca.crt \
    --entrypoint /app/bin/zpr-web-dashboard "$ZPR_OPERATOR_IMAGE" \
    -mode control-room -listen 127.0.0.1:8787
else
    docker start zpr-operator-room >/dev/null
fi
for attempt in {1..30}; do
    if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8787/api/snapshot |
        python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("api_status") == "connected" else 1)'; then
        printf 'PASS: Control Room connected to Visa Service through mTLS Control-Service.\n'
        break
    fi
    [ "$attempt" -lt 30 ] || fail "operator snapshot did not connect; inspect zpr-operator-service and zpr-operator-room logs"
    sleep 1
done
for attempt in {1..30}; do
    if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8787/api/policy |
        python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("configured") and d.get("compiler_ready") else 1)'; then
        printf 'PASS: Policy Repository and compiler available through Control Room.\n'
        break
    fi
    [ "$attempt" -lt 30 ] || fail "Policy Repository not ready; inspect zpr-operator-policy logs"
    sleep 1
done
printf 'Control Room: http://127.0.0.1:8787 (local-only, read-only Visa monitor access).\n'
printf 'Policy drafts persist independently with compiler checks; live apply is not configured.\n'
printf 'Enrollment and named-user login are not configured by this bootstrap.\n'

#!/usr/bin/env bash
# Configure + run ZPR in the local docker env (PLAN.md §5-8). Implements
# docker-configure-run-zpr.md. Mirrors oci-compute/deploy-zpr.sh, but the infra
# is owned by docker-compose.yml — this script does the dynamic host-side parts:
# render @@...@@ templates, generate vs_keys.toml, compile the policy, bring the
# containers up, then launch the two-node ZPR network in order via `docker exec`.
#
#   ./deploy-docker.sh
#
# Re-runnable: retains identities, API credentials and the active Visa database.
# Needs the Linux image built (`docker build --platform linux/amd64 -t zpr-multinode .` in ..).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
MULTI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZPR_DOCS_ROOT="$(cd "$MULTI_DIR/../.." && pwd)"
BIN_DIR="$MULTI_DIR/bin"
CONF_TMPL="$MULTI_DIR/zpr-conf/confs"
INC_DIR="$MULTI_DIR/zpr-conf/include"
ADMIN="$MULTI_DIR/zpr-conf/admin"
ACTION=${1:-deploy}
umask 077
source "$SCRIPT_DIR/runtime-state.sh"
ORGANIZATION_ID=${ZPR_ORGANIZATION_ID:-multinode-demo}
case "$ORGANIZATION_ID" in ''|*[!a-z0-9-]*) echo "invalid organization id: $ORGANIZATION_ID" >&2; exit 2 ;; esac
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  RUNTIME_ROOT="$SCRIPT_DIR"
  CONTAINER_PREFIX=""
  NETWORK_NAME=zpr-local
  COMPOSE_PROJECT=multinode-demo
else
  RUNTIME_ROOT="${ZPR_RUNTIME_ROOT:-$SCRIPT_DIR/runtime/$ORGANIZATION_ID}"
  CONTAINER_PREFIX="$ORGANIZATION_ID-"
  NETWORK_NAME="zpr-$ORGANIZATION_ID"
  COMPOSE_PROJECT="zpr-$ORGANIZATION_ID"
fi
ADMIN_RUNTIME="$RUNTIME_ROOT/admin"
NODE_COMPOSE_OVERRIDE="$RUNTIME_ROOT/compose-nodes.json"
COMPOSE=(docker compose --project-name "$COMPOSE_PROJECT" -f "$MULTI_DIR/docker-compose.yml")
DASHBOARD_DIR="${ZPR_DASHBOARD_DIR:-$ZPR_DOCS_ROOT/zpr-visaservice/zpr-dashboard}"
ZPR_PKI_BIN="$ZPR_DOCS_ROOT/zpr-core/integration-test/lib/zpr-pki"
ORGANIZATION_PROFILE="$DASHBOARD_DIR/cmd/zpr-web-dashboard/examples/organizations/$ORGANIZATION_ID.json"
DIRECTORY_ROOT="$RUNTIME_ROOT/directory"
TRUSTED_SERVICE_BINARY="${ZPR_TRUSTED_SERVICE_BINARY:-$ZPR_DOCS_ROOT/.local-runtime/dashboard-stack/zpr-trusted-service-linux-amd64}"
export ZPR_TRUSTED_SERVICE_BINARY="$TRUSTED_SERVICE_BINARY"
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  COMPOSE+=(--profile legacy)
else
  COMPOSE+=(--profile organization)
fi
gateway_enabled=no
if [ "$ORGANIZATION_ID" != multinode-demo ] && [ -r "$ORGANIZATION_PROFILE" ] &&
  jq -e '.web_gateway.allowed_hosts | type == "array" and length > 0' "$ORGANIZATION_PROFILE" >/dev/null; then
  gateway_enabled=yes
  COMPOSE+=(--profile web-gateway)
  export ZPR_GATEWAY_ALLOWED_HOSTS
  ZPR_GATEWAY_ALLOWED_HOSTS=$(jq -er '.web_gateway.allowed_hosts | join(",")' "$ORGANIZATION_PROFILE")
  export ZPR_GATEWAY_NODE_ADDRESS
  ZPR_GATEWAY_NODE_ADDRESS=$(jq -er '.runtime.nodes[0].substrate_address' "$ORGANIZATION_PROFILE")
fi
if [[ "$ACTION" == stop || "$ACTION" == status ]] && [ -r "$NODE_COMPOSE_OVERRIDE" ]; then
  COMPOSE+=(-f "$NODE_COMPOSE_OVERRIDE")
fi

CONF_ROOT="$RUNTIME_ROOT/conf"        # per-container /conf mounts
BOB_DIR="$RUNTIME_ROOT/bob"        # bob = host-side operator client (not a container)
LOGS_DIR="$RUNTIME_ROOT/logs"
export ZPR_RUNTIME_ROOT="$RUNTIME_ROOT" ZPR_CONTAINER_PREFIX="$CONTAINER_PREFIX" ZPR_NETWORK_NAME="$NETWORK_NAME"
container_name() { printf '%s%s' "$CONTAINER_PREFIX" "$1"; }

case "$ACTION" in
  deploy) ;;
  validate)
    [ "$ORGANIZATION_ID" != multinode-demo ] || { echo "validate requires an organization id" >&2; exit 2; }
    ;;
  stop)
    COMPOSE+=(--profile directory-manager)
    preserve_vs_database
    if [ "$ORGANIZATION_ID" != multinode-demo ]; then
      SIMULATION_ORGANIZATION_ID="$ORGANIZATION_ID" \
        sh "$DASHBOARD_DIR/scripts/dashboard-stack.sh" stop-dns
    fi
    "${COMPOSE[@]}" down
    if [ "$ORGANIZATION_ID" != multinode-demo ] && [ -r "$ORGANIZATION_PROFILE" ] && [ "$(jq -r '.runtime.driver' "$ORGANIZATION_PROFILE")" = docker-multinode ]; then
      node_count=$(jq -er '.runtime.nodes | length' "$ORGANIZATION_PROFILE")
      for ((index = 0; index < node_count; index++)); do
        docker rm -f "${CONTAINER_PREFIX}node$index" >/dev/null 2>&1 || true
      done
    fi
    exit 0
    ;;
  status) "${COMPOSE[@]}" ps; exit 0 ;;
  *) echo "usage: $0 [deploy|validate|stop|status]" >&2; exit 2 ;;
esac

if [ "$ACTION" = validate ]; then
  RUNTIME_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zpr-organization-validation.XXXXXX")
  trap 'rm -rf "$RUNTIME_ROOT"' EXIT
  ADMIN_RUNTIME="$RUNTIME_ROOT/admin"
  NODE_COMPOSE_OVERRIDE="$RUNTIME_ROOT/compose-nodes.json"
  CONF_ROOT="$RUNTIME_ROOT/conf"
  BOB_DIR="$RUNTIME_ROOT/bob"
  LOGS_DIR="$RUNTIME_ROOT/logs"
  DIRECTORY_ROOT="$RUNTIME_ROOT/directory"
  export ZPR_RUNTIME_ROOT="$RUNTIME_ROOT"
else
  preserve_vs_database
  existing_runtime=no
  if [ -s "$CONF_ROOT/vs/vs_keys.toml" ]; then existing_runtime=yes; fi
  if [ -s "$CONF_ROOT/vs/vs_keys.toml" ] &&
     [ ! -s "$RUNTIME_ROOT/state/redis/dump.rdb" ] &&
     [ ! -s "$RUNTIME_ROOT/state/redis/appendonlydir/appendonly.aof.manifest" ]; then
    echo "existing Visa runtime has no recoverable database; refusing policy reset" >&2
    exit 1
  fi
fi

if [ "$ORGANIZATION_ID" != multinode-demo ]; then
  [ -r "$ORGANIZATION_PROFILE" ] || { echo "organization profile missing: $ORGANIZATION_PROFILE" >&2; exit 1; }
  organization_driver=$(jq -er '.runtime.driver' "$ORGANIZATION_PROFILE")
  if [ "$ACTION" = deploy ] && [ "$organization_driver" != docker-multinode ]; then
    echo "organization does not use the docker-multinode driver: $ORGANIZATION_ID" >&2
    exit 1
  fi
  case "$organization_driver" in
    linux-one-node|docker-multinode) ;;
    *) echo "unsupported organization runtime driver: $organization_driver" >&2; exit 1 ;;
  esac
  mkdir -p "$DIRECTORY_ROOT/data"
  ensure_secret() {
    secret_path=$1
    if [ ! -e "$secret_path" ]; then
      (umask 077; openssl rand -hex 24 | tr -d '\r\n' > "$secret_path")
    fi
    if [ ! -f "$secret_path" ] || [ -L "$secret_path" ] || [ ! -s "$secret_path" ]; then
      echo "invalid directory secret file: $secret_path" >&2
      exit 1
    fi
    secret_temp=$(mktemp "${secret_path}.XXXXXX")
    tr -d '\r\n' < "$secret_path" > "$secret_temp"
    chmod 600 "$secret_temp"
    mv "$secret_temp" "$secret_path"
    chmod 600 "$secret_path"
  }
  ensure_secret "$DIRECTORY_ROOT/ldap-password"
  ensure_secret "$DIRECTORY_ROOT/ldap-admin-password"
  : > "$DIRECTORY_ROOT/seed.ldif"
  while IFS= read -r seed_file; do
    case "$seed_file" in ''|/*|../*|*/../*|*/..) echo "unsafe organization LDIF seed path: $seed_file" >&2; exit 1 ;; esac
    case "$(jq -er '.directory.seed_mode' "$ORGANIZATION_PROFILE")" in
      ldif) seed_path="$DASHBOARD_DIR/cmd/zpr-web-dashboard/examples/organizations/$ORGANIZATION_ID/$seed_file" ;;
      pregen) seed_path="$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen/$seed_file" ;;
      *) echo "unsupported organization LDAP seed mode" >&2; exit 1 ;;
    esac
    [ -r "$seed_path" ] || { echo "organization LDIF seed missing: $seed_path" >&2; exit 1; }
    cat "$seed_path" >> "$DIRECTORY_ROOT/seed.ldif"
    printf '\n\n' >> "$DIRECTORY_ROOT/seed.ldif"
  done < <(jq -er '.directory.ldif_files[]' "$ORGANIZATION_PROFILE")
  [ -s "$DIRECTORY_ROOT/seed.ldif" ] || { echo "organization has no LDIF seed files" >&2; exit 1; }
  machine_schema="$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen/zpr-machine.schema"
  [ -r "$machine_schema" ] || { echo "ZPR machine LDAP schema missing: $machine_schema" >&2; exit 1; }
  cp "$machine_schema" "$DIRECTORY_ROOT/zpr-machine.schema"
  if [ ! -s "$DIRECTORY_ROOT/ca.crt" ]; then
    openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 \
      -subj "/CN=$ORGANIZATION_ID directory CA" \
      -keyout "$DIRECTORY_ROOT/ca.key" -out "$DIRECTORY_ROOT/ca.crt" >/dev/null 2>&1
    chmod 600 "$DIRECTORY_ROOT/ca.key"
  fi
  if [ ! -s "$DIRECTORY_ROOT/ldap.crt" ]; then
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=directory" \
      -keyout "$DIRECTORY_ROOT/ldap.key" -out "$DIRECTORY_ROOT/ldap.csr" >/dev/null 2>&1
    openssl x509 -req -in "$DIRECTORY_ROOT/ldap.csr" -CA "$DIRECTORY_ROOT/ca.crt" \
      -CAkey "$DIRECTORY_ROOT/ca.key" -CAcreateserial -days 365 \
      -extfile <(printf 'subjectAltName=DNS:directory,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n') \
      -out "$DIRECTORY_ROOT/ldap.crt" >/dev/null 2>&1
    chmod 600 "$DIRECTORY_ROOT/ldap.key"
  fi
  if [ ! -s "$DIRECTORY_ROOT/provider.crt" ]; then
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=directory" \
      -keyout "$DIRECTORY_ROOT/provider.key" -out "$DIRECTORY_ROOT/provider.csr" >/dev/null 2>&1
    openssl x509 -req -in "$DIRECTORY_ROOT/provider.csr" -CA "$DIRECTORY_ROOT/ca.crt" \
      -CAkey "$DIRECTORY_ROOT/ca.key" -CAcreateserial -days 365 \
      -extfile <(printf 'subjectAltName=DNS:directory\nextendedKeyUsage=serverAuth\n') \
      -out "$DIRECTORY_ROOT/provider.crt" >/dev/null 2>&1
    chmod 600 "$DIRECTORY_ROOT/provider.key"
  fi
  if [ ! -s "$DIRECTORY_ROOT/visa-client.crt" ]; then
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$ORGANIZATION_ID-vs" \
      -keyout "$DIRECTORY_ROOT/visa-client.key" -out "$DIRECTORY_ROOT/visa-client.csr" >/dev/null 2>&1
    openssl x509 -req -in "$DIRECTORY_ROOT/visa-client.csr" -CA "$DIRECTORY_ROOT/ca.crt" \
      -CAkey "$DIRECTORY_ROOT/ca.key" -CAcreateserial -days 365 \
      -extfile <(printf 'extendedKeyUsage=clientAuth\n') \
      -out "$DIRECTORY_ROOT/visa-client.crt" >/dev/null 2>&1
    chmod 600 "$DIRECTORY_ROOT/visa-client.key"
  fi
  chmod 600 "$DIRECTORY_ROOT/ca.key" "$DIRECTORY_ROOT/ldap.key" "$DIRECTORY_ROOT/provider.key" "$DIRECTORY_ROOT/visa-client.key"
  ZPR_DIRECTORY_BASE_DN=$(jq -er '.directory.base_dn' "$ORGANIZATION_PROFILE")
  ZPR_DIRECTORY_IDENTITY_MAPPINGS=$(jq -c '.directory.identity_mappings + (.directory.user_identity_mappings // {})' "$ORGANIZATION_PROFILE")
  ZPR_DIRECTORY_ATTRIBUTES=$(jq -er '([.directory.attributes[]] + [(.directory.user_attributes // [])[]] | unique | join(","))' "$ORGANIZATION_PROFILE")
  export ZPR_DIRECTORY_BASE_DN ZPR_DIRECTORY_IDENTITY_MAPPINGS ZPR_DIRECTORY_ATTRIBUTES
  smoke_identity=$(awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      machine = 0
      uid = ""
      owner = ""
      for (field = 1; field <= NF; field++) {
        if ($field == "objectClass: zprMachine") machine = 1
        if ($field ~ /^uid: /) { uid = $field; sub(/^uid: /, "", uid) }
        if ($field ~ /^zprMachineOwner: /) { owner = $field; sub(/^zprMachineOwner: /, "", owner) }
      }
      if (machine && uid != "" && owner != "") { print uid ":" owner; exit }
    }
  ' "$DIRECTORY_ROOT/seed.ldif")
  [ -n "$smoke_identity" ] || { echo "organization seed has no owned ZPR machine" >&2; exit 1; }
  smoke_machine=${smoke_identity%%:*}
  smoke_owner=${smoke_identity#*:}
  smoke_user_role=$(awk '
    BEGIN { RS = ""; FS = "\n" }
    {
      name = ""
      member = ""
      for (field = 1; field <= NF; field++) {
        if ($field ~ /^cn: /) { name = $field; sub(/^cn: /, "", name) }
        if ($field ~ /^member: uid=/ && member == "") {
          member = $field
          sub(/^member: uid=/, "", member)
          sub(/,.*/, "", member)
        }
      }
      if (name != "" && member != "") { print member ":" name; exit }
    }
  ' "$DIRECTORY_ROOT/seed.ldif")
  [ -n "$smoke_user_role" ] || { echo "organization seed has no direct group membership" >&2; exit 1; }
  smoke_user=${smoke_user_role%%:*}
  smoke_role=${smoke_user_role#*:}
  export ZPR_DIRECTORY_SMOKE_MACHINE="$smoke_machine" ZPR_DIRECTORY_SMOKE_OWNER="$smoke_owner"
  export ZPR_DIRECTORY_SMOKE_USER="$smoke_user" ZPR_DIRECTORY_SMOKE_ROLE="$smoke_role"
  sh "$DASHBOARD_DIR/scripts/prepare-trusted-service.sh"
  base_dn=$(jq -er '.directory.base_dn' "$ORGANIZATION_PROFILE")
  admin_dn="cn=admin,$base_dn"
  reader_dn="cn=zpr-reader,ou=Service Accounts,$base_dn"
  cat > "$DIRECTORY_ROOT/slapd.conf.template" <<EOF
include /etc/ldap/schema/core.schema
include /etc/ldap/schema/cosine.schema
include /etc/ldap/schema/inetorgperson.schema
include /runtime/zpr-machine.schema
pidfile /runtime/slapd.pid
argsfile /runtime/slapd.args
modulepath /usr/lib/ldap
moduleload back_mdb
moduleload accesslog
TLSCACertificateFile /runtime/ca.crt
TLSCertificateFile /runtime/ldap.crt
TLSCertificateKeyFile /runtime/ldap.key
database mdb
maxsize 268435456
suffix "cn=accesslog"
directory /runtime/accesslog
index reqStart eq
access to * by dn.exact="$admin_dn" read by dn.exact="$reader_dn" read by * none
database mdb
maxsize 1073741824
suffix "$base_dn"
directory /runtime/data
rootdn "$admin_dn"
rootpw @@ADMIN_PASSWORD_HASH@@
access to attrs=userPassword by self write by anonymous auth by dn.exact="$admin_dn" write by dn.exact="$reader_dn" read by * none
access to * by dn.exact="$admin_dn" write by dn.exact="$reader_dn" read by users read by * none
overlay accesslog
logdb "cn=accesslog"
logops writes
logsuccess TRUE
logpurge 07+00:00 01+00:00
EOF
  docker build --platform linux/amd64 -t zpr-multinode-directory -f "$MULTI_DIR/Dockerfile.directory" "$MULTI_DIR"
  if [ "$ACTION" = validate ]; then
    docker run --rm --platform linux/amd64 --network none \
      -e ZPR_DIRECTORY_BASE_DN -e ZPR_DIRECTORY_IDENTITY_MAPPINGS -e ZPR_DIRECTORY_ATTRIBUTES \
      -e ZPR_DIRECTORY_SMOKE_MACHINE -e ZPR_DIRECTORY_SMOKE_OWNER \
      -e ZPR_DIRECTORY_SMOKE_USER -e ZPR_DIRECTORY_SMOKE_ROLE -e ZPR_DIRECTORY_SMOKE_TEST=1 \
      -v "$DIRECTORY_ROOT:/runtime" \
      -v "$TRUSTED_SERVICE_BINARY:/app/bin/zpr-trusted-service:ro" \
      zpr-multinode-directory
    if [ "$organization_driver" != docker-multinode ]; then
      echo "Organization directory validated: $ORGANIZATION_ID"
      exit 0
    fi
  fi
fi

write_node_compose_override() {
  node_data=$(jq -ce '.runtime.nodes | select(length >= 1 and length <= 32) | if all(.[]; (.substrate_address | type == "string") and (.zpr_address | type == "string")) then . else error("every Compose node requires substrate_address and zpr_address") end' "$ORGANIZATION_PROFILE")
  temporary_override="$NODE_COMPOSE_OVERRIDE.tmp.$$"
  jq -n \
    --arg prefix "$CONTAINER_PREFIX" \
    --arg runtime "$RUNTIME_ROOT" \
    --arg entrypoint "$SCRIPT_DIR/entrypoint-node.sh" \
    --argjson nodes "$node_data" \
    '{services: (reduce range(0; ($nodes | length)) as $index ({}; . + {("runtime-node-" + ($index | tostring)): {image: "zpr-multinode", platform: "linux/amd64", container_name: ($prefix + "node" + ($index | tostring)), command: ["/bin/sh", "/entrypoint.sh"], cap_add: ["NET_ADMIN"], devices: ["/dev/net/tun"], privileged: true, environment: {ZPR_NODE_ZPR_ADDRESS: $nodes[$index].zpr_address}, volumes: [($entrypoint + ":/entrypoint.sh:ro"), ($runtime + "/conf/node" + ($index | tostring) + ":/conf"), ($runtime + "/logs:/logs")], networks: {"zpr-local": {ipv4_address: $nodes[$index].substrate_address}}}}))}' \
    > "$temporary_override"
  mv "$temporary_override" "$NODE_COMPOSE_OVERRIDE"
  COMPOSE+=(-f "$NODE_COMPOSE_OVERRIDE")
}

# --- Step 0: configured substrate addresses for organization nodes ---
NODE0_ADDR="172.30.0.13"
NODE1_ADDR="172.30.0.10"
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  node_count=2
elif [ "$organization_driver" = docker-multinode ]; then
  node_count=$(jq -er '.runtime.nodes | length' "$ORGANIZATION_PROFILE")
  NODE0_ADDR=$(jq -er '.runtime.nodes[0].substrate_address' "$ORGANIZATION_PROFILE")
  NODE1_ADDR=$(jq -er '.runtime.nodes[1].substrate_address // .runtime.nodes[0].substrate_address' "$ORGANIZATION_PROFILE")
  write_node_compose_override
fi
NODE1_EXT_ADDR="${NODE1_EXT_ADDR:-127.0.0.1}" # host-side bob adapter only
PEER_LINK_WAIT_SECONDS="${PEER_LINK_WAIT_SECONDS:-180}"
echo "configured nodes=$node_count ; node0=$NODE0_ADDR ; node1=$NODE1_ADDR"

# --- render: sub all three tokens, fail loud on any leftover @@...@@ ---
render() {  # $1=template path  $2=output path
  sed -e "s#@@NODE1_ADDR@@#${NODE1_ADDR}#g" \
      -e "s#@@NODE1_EXT_ADDR@@#${NODE1_EXT_ADDR}#g" \
      -e "s#@@NODE0_ADDR@@#${NODE0_ADDR}#g" \
      "$1" > "$2"
  if grep -n '@@[A-Z0-9_]*@@' "$2"; then
    echo "ERROR: unresolved template token(s) above in $(basename "$2")" >&2
    exit 1
  fi
}

prepare_organization_nodes() {
  local node_count index peer_index node_json node_ip node_zpr node_name peer_json peer_ip peer_zpr peer_name link_id
  local pregen organization_include node_config
  node_count=$(jq -er '.runtime.nodes | length' "$ORGANIZATION_PROFILE")
  pregen="$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen"
  organization_include="$RUNTIME_ROOT/include"
  mkdir -p "$organization_include"
  copy_initial_include

  for key_file in client-finance-rsa-pubkey.pem client-operations-rsa-pubkey.pem client-telemetry-rsa-pubkey.pem service-echo-rsa-pubkey.pem service-metrics-rsa-pubkey.pem internet-gateway-rsa-pubkey.pem; do
    cp "$pregen/$key_file" "$organization_include/$key_file"
  done
  cp "$pregen/actor1-rsa.key" "$organization_include/actor1-rsa.key"
  cp "$pregen/actor1.pem" "$organization_include/actor1.pem"
  cp "$pregen/machine-control/simulator-control.pub.pem" "$organization_include/simulator-control.pub.pem"
  for number in $(seq -w 1 20); do
    cp "$pregen/machine-control/machine-$number.pub.pem" "$organization_include/machine-$number.pub.pem"
  done

  for ((index = 0; index < node_count; index++)); do
    node_json=$(jq -ce --argjson index "$index" '.runtime.nodes[$index]' "$ORGANIZATION_PROFILE")
    node_ip=$(jq -er '.substrate_address' <<< "$node_json")
    node_zpr=$(jq -er '.zpr_address' <<< "$node_json")
    node_name="node$index.demo"
    ensure_node_identity "$organization_include" "$index"

    node_config="$CONF_ROOT/node$index/node$index-conf.toml"
    cat > "$node_config" <<EOF
[global]
name = "$node_name"
ca_file = "include/auth-ca.crt"
certificate_file = "include/node$index-noise.crt"
private_key_file = "include/node$index-noise.key"
self_addr = "$node_ip:5000"
zpr_addr = [ "$node_zpr" ]
tun_if = "tun9"
control_path = "/var/run/zpr/control.sock"

[authentication]
auth_private_key = "include/node$index-private-key.pem"

[node]
advertised_substrate_addr = "$node_ip:5000"
local_vs_dock = $([ "$index" -eq 0 ] && printf true || printf false)
[node.peer_noise_certificates]
EOF
    for ((peer_index = 0; peer_index < node_count; peer_index++)); do
      [ "$peer_index" -ne "$index" ] || continue
      peer_json=$(jq -ce --argjson index "$peer_index" '.runtime.nodes[$index]' "$ORGANIZATION_PROFILE")
      peer_zpr=$(jq -er '.zpr_address' <<< "$peer_json")
      printf '"%s" = "include/node%s-noise.crt"\n' "$peer_zpr" "$peer_index" >> "$node_config"
    done
    for ((peer_index = 0; peer_index < node_count; peer_index++)); do
      [ "$peer_index" -ne "$index" ] || continue
      peer_json=$(jq -ce --argjson index "$peer_index" '.runtime.nodes[$index]' "$ORGANIZATION_PROFILE")
      peer_ip=$(jq -er '.substrate_address' <<< "$peer_json")
      peer_zpr=$(jq -er '.zpr_address' <<< "$peer_json")
      if ((index < peer_index)); then link_id="n${index}n${peer_index}"; else link_id="n${peer_index}n${index}"; fi
      cat >> "$node_config" <<EOF

[[node.peers]]
zpr_addr = "$peer_zpr"
substrate_addr = "$peer_ip:5000"
link_id = "$link_id"
EOF
    done
  done

  for container in "$CONF_ROOT"/node* "$CONF_ROOT/vs" "$CONF_ROOT/web0" "$CONF_ROOT/web1" "$CONF_ROOT/alice" "$CONF_ROOT/internet-gateway"; do
    mkdir -p "$container/include"
    cp -R "$organization_include/." "$container/include/"
  done
  dns_node_address=$(jq -er '.runtime.nodes[0].substrate_address' "$ORGANIZATION_PROFILE")
  cat > "$CONF_ROOT/node0/adapter-dns-conf.toml" <<EOF
[global]
ca_file = "include/auth-ca.crt"
zpr_addr = [ "fd00:1:1::1" ]
 tun_if = "tun6"
control_path = "/var/run/zpr/adapter1.sock"
capture_path = "/var/run/zpr/adapter1-cap.sock"

[adapter]
name = "adapter1"
node_addr = "$dns_node_address:5000"
node_public_key_file = "include/node0-noise-pub.pem"
bootstrap_key = "include/actor1-rsa.key"
EOF
}

write_organization_policy_config() {
  local node_count index peer_index node_json node_ip node_zpr node_name
  node_count=$(jq -er '.runtime.nodes | length' "$ORGANIZATION_PROFILE")
  : > "$ADMIN_RUNTIME/multinode-demo.zplc"
  for ((index = 0; index < node_count; index++)); do
    node_json=$(jq -ce --argjson index "$index" '.runtime.nodes[$index]' "$ORGANIZATION_PROFILE")
    node_ip=$(jq -er '.substrate_address' <<< "$node_json")
    node_zpr=$(jq -er '.zpr_address' <<< "$node_json")
    node_name="node$index.demo"
    cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<EOF
[nodes.n$index]
provider = [["device.zpr.adapter.cn", "$node_name"]]
zpr_address = "$node_zpr"

[nodes.n$index.substrate_addrs]
i0 = "$node_ip:5000"

EOF
  done
  for ((index = 0; index < node_count; index++)); do
    for ((peer_index = index + 1; peer_index < node_count; peer_index++)); do
      cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<EOF
[links.n${index}n${peer_index}]
peers = [{node="n$index"}, {node="n$peer_index"}]

EOF
    done
  done
  cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<'EOF'
[visa_service]
dock_node = "n0"

[trusted_services.default]

[trusted_services.attrfile]
api = "file"
returns_attributes = ["location -> user.location", "access -> user.access{}"]
expiration_seconds = 3600

[bootstrap]
EOF
  for ((index = 0; index < node_count; index++)); do
    printf '"node%s.demo" = "/runtime-include/node%s-public-key.pem"\n' "$index" "$index" >> "$ADMIN_RUNTIME/multinode-demo.zplc"
  done
  cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<'EOF'
"vs.zpr" = "/runtime-include/vs-public-key.pem"
"ociweb.demo" = "/runtime-include/web0-public-key.pem"
"premweb.demo" = "/runtime-include/web1-public-key.pem"
"bob" = "/runtime-include/bob-public-key.pem"
"alice" = "/runtime-include/alice-public-key.pem"
"finance-client" = "/runtime-include/client-finance-rsa-pubkey.pem"
"operations-client" = "/runtime-include/client-operations-rsa-pubkey.pem"
"telemetry-client" = "/runtime-include/client-telemetry-rsa-pubkey.pem"
"echo-service" = "/runtime-include/service-echo-rsa-pubkey.pem"
"metrics-service" = "/runtime-include/service-metrics-rsa-pubkey.pem"
"internet-gateway" = "/runtime-include/internet-gateway-rsa-pubkey.pem"
"simulator-control" = "/runtime-include/simulator-control.pub.pem"
"adapter1" = "/runtime-include/actor1.pem"
EOF
  for number in $(seq -w 1 20); do
    printf '"machine-%s" = "/runtime-include/machine-%s.pub.pem"\n' "$number" "$number" >> "$ADMIN_RUNTIME/multinode-demo.zplc"
  done
  cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<'EOF'

[protocols.http]
l4protocol = "TCP"
port = 80

[services.OciWeb]
protocol = "http"
port = "80"
provider = [["device.zpr.adapter.cn", "ociweb.demo"], ["zpr.addr", "fd5a:5052:8888::8"]]

[services.PremWeb]
protocol = "http"
port = "80"
provider = [["device.zpr.adapter.cn", "premweb.demo"], ["zpr.addr", "fd5a:5052:8888::9"]]

[protocols.simulator-control]
l4protocol = "TCP"
port = 8792

[services.SimulatorControlService]
protocol = "simulator-control"
port = "8792"
provider = [["device.zpr.adapter.cn", "simulator-control"], ["zpr.addr", "fd5a:5052:adda:1:ffff:ffff:ffff:fffe"]]

[protocols.dns]
l4protocol = "TCP"
port = 53

[services.ZprDNS]
protocol = "dns"
port = "53"
provider = [["device.zpr.adapter.cn", "adapter1"], ["zpr.addr", "fd00:1:1::1"]]

[protocols.tcp_443]
l4protocol = "iana.TCP"
port = 443

[services.VisaService]
protocol = "tcp_443"
EOF
}

# --- Step 1: assemble per-container /conf dirs (rendered config + whole include/) ---
mkdir -p "$ADMIN_RUNTIME"
cp "$ADMIN/multinode-demo.zpl" "$ADMIN_RUNTIME/multinode-demo.zpl"
mkdir -p "$CONF_ROOT"/{vs,web0,web1,alice,internet-gateway} "$BOB_DIR" "$LOGS_DIR"
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  mkdir -p "$CONF_ROOT"/{node0,node1}
  for c in node0 node1 vs web0 web1 alice; do cp -R "$INC_DIR" "$CONF_ROOT/$c/include"; done
  cp "$CONF_TMPL/node0-conf.toml" "$CONF_ROOT/node0/node0-conf.toml"
  cp "$CONF_TMPL/node1-conf.toml" "$CONF_ROOT/node1/node1-conf.toml"
else
  for ((index = 0; index < $(jq -er '.runtime.nodes | length' "$ORGANIZATION_PROFILE"); index++)); do
    mkdir -p "$CONF_ROOT/node$index"
  done
  prepare_organization_nodes
fi
for c in vs web0 web1 alice internet-gateway; do
  mkdir -p "$CONF_ROOT/$c/include"
  if [ "$ORGANIZATION_ID" = multinode-demo ]; then cp -R "$INC_DIR/." "$CONF_ROOT/$c/include/"; fi
done
render "$CONF_TMPL/adapter-web0-conf.toml.template" "$CONF_ROOT/web0/adapter-web0-conf.toml"
render "$CONF_TMPL/adapter-vs-conf.toml.template"   "$CONF_ROOT/vs/adapter-vs-conf.toml"
render "$CONF_TMPL/adapter-web1-conf.toml.template" "$CONF_ROOT/web1/adapter-web1-conf.toml"
render "$CONF_TMPL/adapter-alice-local-conf.toml.template" "$CONF_ROOT/alice/adapter-alice-conf.toml"
if [ "$gateway_enabled" = yes ]; then
  cp "$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen/internet-gateway-rsa.key" \
    "$CONF_ROOT/internet-gateway/internet-gateway-rsa.key"
  chmod 600 "$CONF_ROOT/internet-gateway/internet-gateway-rsa.key"
fi
cp "$SCRIPT_DIR/vs.toml" "$CONF_ROOT/vs/vs.toml"
if [ "$ORGANIZATION_ID" != multinode-demo ]; then
  jq -r -f "$DASHBOARD_DIR/scripts/render-node-geography.jq" "$ORGANIZATION_PROFILE" >> "$CONF_ROOT/vs/vs.toml"
fi
cp "$ADMIN/attrfile.json" "$CONF_ROOT/vs/attrfile.json"   # policy attributes, read by vs
if [ -r "$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen/demo_file.json" ]; then
  cp "$ZPR_DOCS_ROOT/.local-runtime/linux-integration/pregen/demo_file.json" "$CONF_ROOT/vs/demo_file.json"
fi
cp "$CONF_TMPL/zpr-dashboard-config.toml" "$CONF_ROOT/vs/config.toml"  # zpr-dashboard reads ./config.toml
if [ "$ORGANIZATION_ID" != multinode-demo ]; then
  cp "$DIRECTORY_ROOT/ca.crt" "$CONF_ROOT/vs/organization-directory-ca.crt"
  cp "$DIRECTORY_ROOT/visa-client.crt" "$CONF_ROOT/vs/organization-directory-client.crt"
  cp "$DIRECTORY_ROOT/visa-client.key" "$CONF_ROOT/vs/organization-directory-client.key"
  chmod 600 "$CONF_ROOT/vs/organization-directory-client.key"
  if [ "$ORGANIZATION_ID" = "great-lakes" ]; then
    cat >> "$CONF_ROOT/vs/vs.toml" <<EOF

[trusted_service_http.great_lakes_ldap]
url = "https://directory:8443"
ca_cert = "/conf/organization-directory-ca.crt"
client_cert = "/conf/organization-directory-client.crt"
client_key = "/conf/organization-directory-client.key"
EOF
  fi
  if [ "$ORGANIZATION_ID" = "northstar" ]; then
    cat >> "$CONF_ROOT/vs/vs.toml" <<EOF

[trusted_service_http.demo_ldap]
url = "https://directory:8443"
ca_cert = "/conf/organization-directory-ca.crt"
client_cert = "/conf/organization-directory-client.crt"
client_key = "/conf/organization-directory-client.key"

[trusted_service_http.demo_user_ldap]
url = "https://directory:8443"
ca_cert = "/conf/organization-directory-ca.crt"
client_cert = "/conf/organization-directory-client.crt"
client_key = "/conf/organization-directory-client.key"
EOF
  fi
  cat >> "$CONF_ROOT/vs/vs.toml" <<EOF

[trusted_service_http.redwood_directory]
url = "https://directory:8443"
ca_cert = "/conf/organization-directory-ca.crt"
client_cert = "/conf/organization-directory-client.crt"
client_key = "/conf/organization-directory-client.key"

[trusted_service_http.redwood_user_directory]
url = "https://directory:8443"
ca_cert = "/conf/organization-directory-ca.crt"
client_cert = "/conf/organization-directory-client.crt"
client_key = "/conf/organization-directory-client.key"
EOF
fi

# bob, the host-side operator client (stays on host, next to client.key)
render "$CONF_TMPL/adapter-bob-conf.toml.template" "$BOB_DIR/adapter-bob-conf.toml"
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  ln -sfn "$INC_DIR" "$BOB_DIR/include"
else
  ln -sfn "$RUNTIME_ROOT/include" "$BOB_DIR/include"
fi

# --- Step 2 (§7.3): vs_keys.toml + client.key ---
ensure_api_credentials
echo "operator key written to $BOB_DIR/client.key"
echo "read-only monitor key written to $BOB_DIR/web-monitor.key"

# --- Step 3: compile policy on host (needs ../include keys the .zplc references) ---
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  render "$ADMIN/multinode-demo.zplc.template" "$ADMIN_RUNTIME/multinode-demo.zplc"
else
  write_organization_policy_config
fi
if [ "$ORGANIZATION_ID" != multinode-demo ]; then
  cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<'EOF'

[trusted_services.redwood_directory]
api = "rest/1"
returns_attributes = ["ou -> device.redwood.department", "title -> device.redwood.title", "l -> device.redwood.location", "zprMachineType -> device.redwood.machine_type", "zprMachineLocation -> device.redwood.location", "zprMachineSecure -> device.redwood.secure", "zprMachineOwner -> device.redwood.owner", "role -> device.redwood.role{}"]
expiration_seconds = 3600

[trusted_services.redwood_user_directory]
api = "rest/1"
returns_attributes = ["cn -> user.name", "mail -> user.email", "ou -> user.department", "title -> user.title", "l -> user.location", "role -> user.role{}"]
expiration_seconds = 3600
EOF
  if [ "$ORGANIZATION_ID" = "great-lakes" ]; then
    cat >> "$ADMIN_RUNTIME/multinode-demo.zplc" <<'EOF'

[trusted_services.great_lakes_ldap]
api = "rest/1"
returns_attributes = ["ou -> device.greatlakes.department", "zprMachineLocation -> device.greatlakes.location"]
expiration_seconds = 3600
EOF
  fi
fi
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  docker run --rm --platform linux/amd64 \
    -v "$MULTI_DIR:/demo:ro" -v "$ADMIN_RUNTIME:/demo/zpr-conf/admin" \
    -w /demo/zpr-conf/admin zpr-multinode \
    /app/bin/zplc --config multinode-demo.zplc multinode-demo.zpl
else
  docker run --rm --platform linux/amd64 \
    -v "$MULTI_DIR:/demo:ro" -v "$ADMIN_RUNTIME:/demo/zpr-conf/admin" \
    -v "$RUNTIME_ROOT/include:/runtime-include:ro" \
    -w /demo/zpr-conf/admin zpr-multinode \
    /app/bin/zplc --config multinode-demo.zplc multinode-demo.zpl
fi
mv "$ADMIN_RUNTIME/multinode-demo.bin2" "$CONF_ROOT/vs/multinode-demo.bin2"
if [ "$ACTION" = validate ]; then
  echo "Organization directory and multi-node policy artifacts validated: $ORGANIZATION_ID"
  exit 0
fi

# --- Step 4: bring up infra (entrypoints set up tun9 / valkey / nginx) ---
"${COMPOSE[@]}" up -d --force-recreate --remove-orphans
sleep 2
if [ "$ORGANIZATION_ID" != multinode-demo ]; then
  directory_container=$(container_name directory)
  directory_base_dn=$(jq -er '.directory.base_dn' "$ORGANIZATION_PROFILE")
  directory_health_uid=$(jq -er '.directory.health_uid' "$ORGANIZATION_PROFILE")
  lookup_request=$(jq -cn --arg uid "$directory_health_uid" '{identities:[{key:"device.zpr.adapter.cn",value:$uid}]}')
  directory_ready=no
  for _ in $(seq 30); do
    if docker exec "$directory_container" env LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/runtime/ca.crt \
        ldapsearch -LLL -x -H ldaps://127.0.0.1:1636 \
        -D "cn=zpr-reader,ou=Service Accounts,$directory_base_dn" -y /runtime/ldap-password \
        -b "$directory_base_dn" "(uid=$directory_health_uid)" uid >/dev/null 2>&1 &&
       docker exec "$directory_container" curl -fsS --connect-timeout 1 --max-time 5 \
        --cacert /runtime/ca.crt --cert /runtime/visa-client.crt --key /runtime/visa-client.key \
        -H 'Content-Type: application/json' --data-binary "$lookup_request" \
        https://directory:8443/v1/attributes >/dev/null 2>&1; then
      directory_ready=yes
      break
    fi
    sleep 1
  done
  if [ "$directory_ready" != yes ]; then
    docker logs "$directory_container" >&2 || true
    echo "organization LDAP or trusted service did not become ready: $ORGANIZATION_ID" >&2
    exit 1
  fi
  sh "$SCRIPT_DIR/start-directory-manager.sh"
fi
# tee to a mounted /logs file so output survives the tmux session dying.
launch() {  # $1=container $2=session/logname $3=command(run with cwd /conf)
  local container
  container=$(container_name "$1")
  docker exec "$container" tmux kill-session -t "$2" 2>/dev/null || true
  docker exec "$container" tmux new-session -d -s "$2" -c /conf "$3 2>&1 | tee /logs/$2.log"
  sleep 1
  docker exec "$container" tmux has-session -t "$2" 2>/dev/null \
    && echo "[$container] $2 running in tmux" \
    || { echo "ERROR: $2 exited immediately in $1 — see $LOGS_DIR/$2.log" >&2; exit 1; }
}

wait_for_peer() { # $1=local node container $2=expected substrate address
  local summary
  echo "[$1] waiting for peer $2:5000 to become Active"
  for _ in $(seq "$((PEER_LINK_WAIT_SECONDS / 2))"); do
    summary=$(docker exec "$(container_name "$1")" /app/bin/ph-cli -p /var/run/zpr/control.sock link show 2>/dev/null || true)
    if grep -Fq "$2:5000 (Active)" <<< "$summary"; then
      echo "[$1] peer $2 is Active"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: [$1] peer $2 did not become Active within $PEER_LINK_WAIT_SECONDS seconds" >&2
  tail -n 80 "$LOGS_DIR/${1}.log" >&2 || true
  return 1
}

wait_for_adapter() { # $1=node container $2=adapter substrate address
  local summary
  echo "[$1] waiting for adapter $2 to become Active"
  for _ in $(seq 30); do
    summary=$(docker exec "$(container_name "$1")" /app/bin/ph-cli -p /var/run/zpr/control.sock link show 2>/dev/null || true)
    if grep -Eq "$2:[0-9]+ \\(Active\\)" <<< "$summary"; then
      echo "[$1] adapter $2 is Active"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: [$1] adapter $2 did not become Active within 60 seconds" >&2
  tail -n 80 "$LOGS_DIR/${1}-adapter.log" >&2 || true
  return 1
}

policy_exists=$(docker exec "$(container_name vs)" redis-cli --raw EXISTS policy:current)
vs_command=$(visa_start_command "$policy_exists")
wait_for_visa_lease "$(container_name vs)"
launch vs vs "$vs_command"
for ((index = 0; index < node_count; index++)); do
  launch "node$index" "node$index" "/app/bin/ph node -c node$index-conf.toml"
done
launch vs vs-adapter "/app/bin/ph adapter -c adapter-vs-conf.toml"

for ((index = 0; index < node_count; index++)); do
  for ((peer_index = 0; peer_index < node_count; peer_index++)); do
    [ "$peer_index" -ne "$index" ] || continue
    if [ "$ORGANIZATION_ID" = multinode-demo ]; then
      peer_address=$([ "$peer_index" -eq 0 ] && printf '%s' "$NODE0_ADDR" || printf '%s' "$NODE1_ADDR")
    else
      peer_address=$(jq -er --argjson index "$peer_index" '.runtime.nodes[$index].substrate_address' "$ORGANIZATION_PROFILE")
    fi
    wait_for_peer "node$index" "$peer_address"
  done
done

for container in web0 web1; do
  container_id=$(container_name "$container")
  docker exec "$container_id" curl -fsS http://localhost:80 >/dev/null \
    && echo "[$container_id] nginx serving :80" \
    || { echo "ERROR: nginx not serving in $container_id" >&2; exit 1; }
done
if ((node_count > 1)); then
  launch web0 web0-adapter "env ZPR_ADAPTER_SERVICES=OciWeb /app/bin/ph adapter -c adapter-web0-conf.toml"
  wait_for_adapter node0 172.30.0.14
else
  echo "[web0] OciWeb smoke adapter skipped for single-node organization $ORGANIZATION_ID"
fi
if [[ "${START_PREMWEB_ADAPTER:-0}" == "1" ]]; then
  launch web1 web1-adapter "env ZPR_ADAPTER_SERVICES=PremWeb /app/bin/ph adapter -c adapter-web1-conf.toml"
  wait_for_adapter node1 172.30.0.12
else
  echo "[web1] PremWeb ZPR adapter skipped (set START_PREMWEB_ADAPTER=1 to enable)"
fi
if [ "$gateway_enabled" = yes ]; then
  gateway_container=$(container_name internet-gateway)
  docker restart "$gateway_container" >/dev/null
  gateway_substrate=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$gateway_container")
  case "$gateway_substrate" in ''|*[!0-9.]*) echo "internet gateway has no valid IPv4 substrate address" >&2; exit 1 ;; esac
  [ -n "$gateway_substrate" ] || { echo "internet gateway container has no substrate address" >&2; exit 1; }
  wait_for_adapter node0 "$gateway_substrate"
  gateway_address=
  for _ in $(seq 30); do
    if gateway_address=$(docker exec "$gateway_container" ip -6 -o addr show dev tun10 scope global | awk '$4 ~ /^fd5a:5052:adda:1:/ { split($4, address, "/"); print address[1]; exit }') &&
       [ -n "$gateway_address" ]; then
      break
    fi
    sleep 1
  done
  [ -n "$gateway_address" ] || { echo "Visa-assigned Gateway ZPR address unavailable" >&2; exit 1; }
  gateway_ready=no
  for _ in $(seq 30); do
    if docker exec "$gateway_container" curl -g -fsS --connect-timeout 1 --max-time 3 \
      "http://[$gateway_address]:8082/health" >/dev/null 2>&1; then
      gateway_ready=yes
      break
    fi
    sleep 1
  done
  if [ "$gateway_ready" != yes ]; then
    docker logs "$gateway_container" >&2 || true
    echo "organization web gateway did not become ready: $ORGANIZATION_ID" >&2
    exit 1
  fi
  echo "[$gateway_container] allowlisted web gateway ready on internet-gateway.svc.zpr:8082"
fi
if [ "$ORGANIZATION_ID" = multinode-demo ]; then
  launch alice alice-adapter "/app/bin/ph adapter -c adapter-alice-conf.toml"

  echo "[alice] checking policy-authorized HTTP to OciWeb across the node peer"
  alice_response=""
  for _ in $(seq 20); do
    if alice_response=$(docker exec "$(container_name alice)" curl -g -6 -fsS --max-time 5 'http://[fd5a:5052:8888::8]/' 2>/dev/null); then
      break
    fi
    sleep 2
  done
  if [[ -z "$alice_response" ]]; then
    echo "ERROR: Alice could not reach OciWeb across node0-node1" >&2
    tail -n 80 "$LOGS_DIR/alice-adapter.log" "$LOGS_DIR/web0-adapter.log" "$LOGS_DIR/node0.log" "$LOGS_DIR/node1.log" >&2 || true
    exit 1
  fi
  echo "[alice] OciWeb reachable across node0-node1"
else
  echo "[alice] generic OciWeb smoke skipped for organization profile $ORGANIZATION_ID"
fi

if [ "$ORGANIZATION_ID" != multinode-demo ] &&
   [ ! -f "$RUNTIME_ROOT/policy-bootstrap-required" ]; then
  SIMULATION_ORGANIZATION_ID="$ORGANIZATION_ID" \
    sh "$DASHBOARD_DIR/scripts/dashboard-stack.sh" start-dns
fi

cat <<EOF

Done. Local two-node ZPR env is up.
  Logs:   tail -f $LOGS_DIR/*.log
  Attach: docker exec -it <${CONTAINER_PREFIX}node0|${CONTAINER_PREFIX}node1|${CONTAINER_PREFIX}vs|${CONTAINER_PREFIX}web0|${CONTAINER_PREFIX}web1|${CONTAINER_PREFIX}alice> tmux attach -t <session>   (Ctrl-b d to detach)
  bob:    adapter config + key on host at $BOB_DIR/
  Teardown: ${COMPOSE[*]} down
EOF

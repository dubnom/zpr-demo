#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'init-demo-identities: %s\n' "$1" >&2; exit 1; }
trap 'fail "operation failed at line $LINENO; incomplete state is retained and must not be reused or automatically rotated"' ERR

generate() {
  local operation=$1
  shift
  "$@" 2>/dev/null || fail "$operation failed; incomplete state retained without rotation"
}

metadata() {
  if stat -c '%u %a %h' "$1" 2>/dev/null; then return; fi
  stat -f '%u %Lp %l' "$1"
}

check_directory() {
  local owner mode links
  [ -d "$1" ] && [ ! -L "$1" ] ||   fail "state directory must not be a symlink or non-directory: $1"
  read -r owner mode links <<< "$(metadata "$1")"
  [ "$owner" = "$UID_NUMBER" ] && [ "$mode" = 700 ] ||
    fail "state directory must be owned by the invoking user with mode 0700: $1"
}

check_file() {
  local owner mode links
  [ -f "$1" ] && [ ! -L "$1" ] && [ -s "$1" ] ||
    fail "state file must be a nonempty regular file, never a symlink: $1"
  read -r owner mode links <<< "$(metadata "$1")"
  [ "$owner" = "$UID_NUMBER" ] && [ "$mode" = 600 ] && [ "$links" = 1 ] ||
    fail "state file must be single-link, invoking-user-owned with mode 0600: $1 (owner=$owner mode=$mode links=$links)"
}

check_runtime_entry() {
  local owner mode links
  if [ -L "$1" ] || { [ ! -f "$1" ] && [ ! -d "$1" ]; }; then
    fail "runtime state must be a regular file or directory, never a symlink: $1"
  fi
  read -r owner mode links <<< "$(metadata "$1")"
  if [ "$owner" != "$UID_NUMBER" ] || (( (8#$mode & 0022) != 0 )); then
    fail "runtime state must be invoking-user-owned and not writable by others: $1 (owner=$owner mode=$mode)"
  fi
  if [ -f "$1" ]; then
    [ "$links" = 1 ] || fail "runtime file must have a single link: $1"
  fi
}

check_parents() {
  local current=/ part owner mode links
  local -a parts
  IFS=/ read -r -a parts <<< "${STATE_DIR#/}"
  for part in "${parts[@]}"; do
    current="${current%/}/$part"
    [ "$current" != "$STATE_DIR" ] || break
    [ -d "$current" ] && [ ! -L "$current" ] ||
      fail "state ancestors must be existing directories without symlinks"
    read -r owner mode links <<< "$(metadata "$current")"
    [ "$owner" = 0 ] || [ "$owner" = "$UID_NUMBER" ] ||
      fail "state ancestors must be owned by root or the invoking user"
    if (( (8#$mode & 0022) != 0 )); then
      (( (8#$mode & 01000) != 0 )) && [ "$owner" = 0 ] ||
        fail "state ancestors must not be writable by other users"
    fi
  done
}

has_path() {
  local wanted=$1 candidate
  shift
  for candidate in "$@"; do [ "$wanted" != "$candidate" ] || return 0; done
  return 1
}

check_tree() {
  local directory=$1 entry relative
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    relative=${entry#"$STATE_DIR/"}
    [ ! -L "$entry" ] || fail "state must not contain symlinks: $entry"
    case "$relative" in
      state/redis/.zpr-demo-policy-v1|state/redis/.zpr-demo-policy-bootstrap-pending)
        check_file "$entry"
        continue ;;
      state/redis/*|logs/*)
        check_runtime_entry "$entry"
        if [ -d "$entry" ]; then check_tree "$entry"; fi
        continue ;;
    esac
    if [ -d "$entry" ]; then
      check_directory "$entry"
      if ! has_path "$relative" "${DIRECTORIES[@]}"; then
        case "$relative" in conf/node0/include|conf/node1/include|conf/vs/include|conf/web0/include|conf/web1/include|conf/alice/include|state/redis/*|logs/*) ;; *) fail "unexpected state directory" ;; esac
      fi
      check_tree "$entry"
    else
      check_file "$entry"
      if ! has_path "$relative" "${FILES[@]}" .zpr-demo-state-v1; then
        case "$relative" in state/redis/*|logs/*) ;; *) fail "unexpected state file" ;; esac
      fi
    fi
  done
}

manifest() {
  local relative digest
  printf 'zpr-demo-state-v1\n'
  for relative in "${FILES[@]}"; do
    digest=$(openssl dgst -sha256 "$STATE_DIR/$relative") ||
      fail "cannot fingerprint the complete-state inventory"
    printf '%s %s\n' "${digest##* }" "$relative"
  done
}

tool() {
  local program=$1 directory=$2
  shift 2
  docker run --rm --pull never --platform linux/amd64 --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges \
    --user "$UID_NUMBER:$GID_NUMBER" \
    --mount "type=bind,source=$STATE_DIR/$directory,target=/$directory" \
    --workdir "/$directory" --entrypoint "/app/bin/$program" "$IMAGE" "$@"
}

[ "$#" = 2 ] && [ "$1" = prepare ] ||
  fail "usage: init-demo-identities.sh prepare <absolute-state-dir>"
STATE_DIR=$2
case "$STATE_DIR" in
  /|*/|*//*|*/./*|*/../*|*/.|*/..|*[!a-zA-Z0-9_./-]*)
    fail "state path must be canonical and absolute using letters, digits, slash, dot, underscore or hyphen" ;;
  /*) ;;
  *) fail "state path must be absolute" ;;
esac
UID_NUMBER=$(id -u)
GID_NUMBER=$(id -g)
check_parents

DIRECTORIES=(include conf bob admin state state/redis logs)
FILES=(include/auth-ca.key include/auth-ca.crt include/admin-tls-key.pem include/admin-tls-cert.pem)
for identity in alice bob node0 node1 vs web0 web1; do
  FILES+=("include/$identity-private-key.pem" "include/$identity-public-key.pem")
done
for identity in node0 node1 vs; do
  FILES+=("include/$identity-noise.key" "include/$identity-noise-pub.pem" "include/$identity-noise.crt")
done
for service in node0 node1 vs web0 web1 alice; do
  DIRECTORIES+=("conf/$service")
  case "$service" in
    node*) FILES+=("conf/$service/$service-conf.toml") ;;
    *) FILES+=("conf/$service/adapter-$service-conf.toml") ;;
  esac
done
FILES+=(conf/vs/vs.toml conf/vs/config.toml conf/vs/attrfile.json conf/vs/vs_keys.toml
  conf/vs/multinode-demo.bin2 bob/adapter-bob-conf.toml bob/client.key bob/web-monitor.key
  admin/multinode-demo.zpl admin/multinode-demo.zplc admin/multinode-demo.bin2)

if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
  check_directory "$STATE_DIR"
  if [ -e "$STATE_DIR/.zpr-demo-state-v1" ] || [ -L "$STATE_DIR/.zpr-demo-state-v1" ]; then
    check_tree "$STATE_DIR"
    for directory in "${DIRECTORIES[@]}"; do check_directory "$STATE_DIR/$directory"; done
    for file in "${FILES[@]}"; do check_file "$STATE_DIR/$file"; done
    [ "$(cat "$STATE_DIR/.zpr-demo-state-v1")" = "$(manifest)" ] ||
      fail "complete-state inventory has changed; refusing automatic repair or rotation"
    printf 'Existing complete demo identity state preserved.\n'
    exit 0
  fi
  for entry in "$STATE_DIR"/* "$STATE_DIR"/.[!.]* "$STATE_DIR"/..?*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || fail "partial state exists; refusing automatic rotation"
  done
else
  mkdir -m 700 "$STATE_DIR"
fi

PACKAGE_DIR=${ZPR_DEMO_PACKAGE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
PKI="$PACKAGE_DIR/runtime/zpr-pki"
[ -f "$PKI" ] && [ ! -L "$PKI" ] && [ -x "$PKI" ] || fail "package runtime/zpr-pki executable is required"
[ -f "$PACKAGE_DIR/runtime/image-reference" ] && [ ! -L "$PACKAGE_DIR/runtime/image-reference" ] ||
  fail "package runtime/image-reference is required"
IMAGE=$(cat "$PACKAGE_DIR/runtime/image-reference")
[[ "$IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._/:@+-]{0,254}$ ]] ||
  fail "invalid package image-reference"
command -v openssl >/dev/null || fail "OpenSSL is required"
command -v docker >/dev/null || fail "Docker CLI is required for isolated package tool commands"
command -v python3 >/dev/null || fail "Python 3 is required to validate the pinned package image"
PINNED_IMAGE=$(python3 - "$PACKAGE_DIR/manifest.json" "$IMAGE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
component = manifest["component"]
image_id = component["docker_image_id"]
if (manifest.get("package_id") != "zpr-demo-image"
        or manifest.get("platform") != "linux/amd64"
        or component.get("image_reference") != sys.argv[2]
        or not isinstance(image_id, str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id)):
    raise SystemExit("invalid pinned ZPR package image")
print(image_id)
PY
) || fail "cannot validate the pinned package image"
[ "$(docker image inspect --format '{{.Id}}|{{.Os}}|{{.Architecture}}' "$IMAGE")" = "$PINNED_IMAGE|linux|amd64" ] ||
  fail "imported image does not match the pinned Linux/amd64 package image"
IMAGE=$PINNED_IMAGE
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )) ||
  fail "fresh initialization requires Bash 4.1 or newer for the packaged zpr-pki helper"
ASSETS="$PACKAGE_DIR/runtime/assets/config"
asset_files=(admin/attrfile.json admin/multinode-demo.zpl admin/multinode-demo.zplc.template
  confs/node0-conf.toml confs/node1-conf.toml confs/zpr-dashboard-config.toml vs.toml)
for service in vs web0 web1 bob; do asset_files+=("confs/adapter-$service-conf.toml.template"); done
asset_files+=(confs/adapter-alice-local-conf.toml.template)
for asset in "${asset_files[@]}"; do
  [ -f "$ASSETS/$asset" ] && [ ! -L "$ASSETS/$asset" ] && [ -s "$ASSETS/$asset" ] ||
    fail "required non-secret package configuration asset is missing or unsafe"
done

for directory in "${DIRECTORIES[@]}"; do mkdir -m 700 "$STATE_DIR/$directory"; done
(
  cd "$STATE_DIR/include"
  generate "CA key generation" "$PKI" gencakey > auth-ca.key
  generate "CA certificate generation" "$PKI" gencacert '/CN=ZPR multinode demo installation CA' 365 < auth-ca.key > auth-ca.crt
  for identity in alice bob node0 node1 vs web0 web1; do
    generate "RSA key generation" openssl genrsa -out "$identity-private-key.pem" 2048
    generate "RSA public key extraction" openssl pkey -in "$identity-private-key.pem" -pubout -out "$identity-public-key.pem"
  done
  for identity in node0 node1 vs; do
    generate "Noise key generation" "$PKI" genkey > "$identity-noise.key"
    generate "Noise public key extraction" "$PKI" pubkey < "$identity-noise.key" > "$identity-noise-pub.pem"
    if [ "$identity" = vs ]; then common_name=vs.zpr; else common_name=$identity.demo; fi
    generate "Noise certificate generation" "$PKI" gensignedcert auth-ca.crt auth-ca.key "/CN=$common_name" 365 \
      < "$identity-noise-pub.pem" > "$identity-noise.crt"
  done
  generate "Admin TLS generation" openssl req -new -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=vs.zpr' \
    -addext 'subjectAltName=DNS:vs.zpr,IP:fd5a:5052::1,IP:127.0.0.1' \
    -addext 'extendedKeyUsage=serverAuth' \
    -keyout admin-tls-key.pem -out admin-tls-cert.pem
)
# OpenSSL's CA signing operation may create this serial file alongside the CA.
if [ -f "$STATE_DIR/include/auth-ca.srl" ] && [ ! -L "$STATE_DIR/include/auth-ca.srl" ]; then
  rm "$STATE_DIR/include/auth-ca.srl"
fi

render() {
  sed -e 's/@@NODE0_ADDR@@/172.30.0.13/g' \
    -e 's/@@NODE1_ADDR@@/172.30.0.10/g' \
    -e 's/@@NODE1_EXT_ADDR@@/127.0.0.1/g' "$ASSETS/$1" > "$STATE_DIR/$2"
  if grep -q '@@[A-Z0-9_]*@@' "$STATE_DIR/$2"; then fail "unresolved package configuration token"; fi
}
for index in 0 1; do
  render "confs/node$index-conf.toml" "conf/node$index/node$index-conf.toml"
done
for service in vs web0 web1 bob; do
  if [ "$service" = bob ]; then directory=bob; else directory=conf/$service; fi
  render "confs/adapter-$service-conf.toml.template" "$directory/adapter-$service-conf.toml"
done
render confs/adapter-alice-local-conf.toml.template conf/alice/adapter-alice-conf.toml
render vs.toml conf/vs/vs.toml
render confs/zpr-dashboard-config.toml conf/vs/config.toml
render admin/attrfile.json conf/vs/attrfile.json
render admin/multinode-demo.zpl admin/multinode-demo.zpl
render admin/multinode-demo.zplc.template admin/multinode-demo.zplc
tool vsapikey conf/vs create --init readwrite client /conf/vs/vs_keys.toml > "$STATE_DIR/bob/client.key" 2>/dev/null
tool vsapikey conf/vs create read web-monitor /conf/vs/vs_keys.toml > "$STATE_DIR/bob/web-monitor.key" 2>/dev/null
compiler_mounts=(--mount "type=bind,source=$STATE_DIR/admin,target=/admin")
for identity in alice bob node0 node1 vs web0 web1; do
  compiler_mounts+=(--mount "type=bind,source=$STATE_DIR/include/$identity-public-key.pem,target=/include/$identity-public-key.pem,readonly")
done
generate "policy compilation" docker run --rm --pull never --platform linux/amd64 --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges --user "$UID_NUMBER:$GID_NUMBER" \
  "${compiler_mounts[@]}" --workdir /admin --entrypoint /app/bin/zplc "$IMAGE" \
  --config multinode-demo.zplc multinode-demo.zpl >/dev/null
cp "$STATE_DIR/admin/multinode-demo.bin2" "$STATE_DIR/conf/vs/multinode-demo.bin2"
for file in "${FILES[@]}"; do
  [ -f "$STATE_DIR/$file" ] && [ ! -L "$STATE_DIR/$file" ] || fail "generator did not produce the required file layout"
  chmod 600 "$STATE_DIR/$file"
done
check_tree "$STATE_DIR"
for file in "${FILES[@]}"; do check_file "$STATE_DIR/$file"; done
manifest > "$STATE_DIR/.zpr-demo-state-v1"
check_file "$STATE_DIR/.zpr-demo-state-v1"
printf 'Fresh demo identity state prepared; no services were started.\n'

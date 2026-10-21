#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

fail() { printf 'test-init-demo-identities: %s\n' "$1" >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
[ "$#" = 0 ] || fail "usage: test-init-demo-identities.sh"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/zpr-demo-identities-test.XXXXXXXX")
TEMP=$(cd "$TEMP" && pwd -P)
cleanup() {
  # This is the exact private test directory created above, never a supplied path.
  chmod -R u+rwX "$TEMP"
  rm -rf -- "$TEMP"
}
trap cleanup EXIT
mkdir -m 700 "$TEMP/package" "$TEMP/package/runtime" "$TEMP/commands" "$TEMP/unrelated"
cp "$SCRIPT_DIR/init-demo-identities.sh" "$TEMP/package/runtime/init-demo-identities.sh"
cat > "$TEMP/package/runtime/zpr-pki" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  gencakey) printf 'mock CA key\n' ;;
  gencacert) [ "$#" = 3 ]; cat >/dev/null; printf 'mock CA certificate\n' ;;
  genkey) printf 'mock Noise private key\n' ;;
  pubkey) cat >/dev/null; printf 'mock Noise public key\n' ;;
  gensignedcert)
    [ "$#" = 5 ] && [ -s "$2" ] && [ -s "$3" ]
    cat >/dev/null
    printf 'mock Noise certificate\n' ;;
  *) exit 96 ;;
esac
EOF
chmod 700 "$TEMP/package/runtime/"*.sh "$TEMP/package/runtime/zpr-pki"
printf 'zpr-multinode:identity-test\n' > "$TEMP/package/runtime/image-reference"
printf '{"package_id":"zpr-demo-image","platform":"linux/amd64","component":{"image_reference":"zpr-multinode:identity-test","docker_image_id":"sha256:%064d"}}\n' 1 > "$TEMP/package/manifest.json"
ASSETS="$TEMP/package/runtime/assets/config"
mkdir -p "$ASSETS/admin" "$ASSETS/confs"
printf 'mock attrfile\n' > "$ASSETS/admin/attrfile.json"
printf 'mock policy source\n' > "$ASSETS/admin/multinode-demo.zpl"
printf '"node0.demo" = "../include/node0-public-key.pem"\n' > "$ASSETS/admin/multinode-demo.zplc.template"
printf 'mock VS config\n' > "$ASSETS/vs.toml"
printf 'mock dashboard config\n' > "$ASSETS/confs/zpr-dashboard-config.toml"
for index in 0 1; do
  printf 'private_key_file = "include/node%s-noise.key"\n' "$index" > "$ASSETS/confs/node$index-conf.toml"
done
for service in vs web0 web1 bob alice-local; do
  case "$service" in vs|web0) node=0 ;; *) node=1 ;; esac
  printf 'node_public_key_file = "include/node%s-noise-pub.pem"\nnode_addr = "@@NODE1_ADDR@@:5000"\n' "$node" \
    > "$ASSETS/confs/adapter-$service-conf.toml.template"
done
export TEST_ROOT="$TEMP" TEST_DOCKER_LOG="$TEMP/docker.log"
cat > "$TEMP/commands/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = image ]; then
  printf 'sha256:%064d|linux|amd64\n' 1
  exit 0
fi
[ "$1" = run ] || exit 90
shift
conf= admin= identities= program=
printf 'tool\n' >> "$TEST_DOCKER_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rm|--read-only) shift ;;
    --pull) [ "$2" = never ]; shift 2 ;;
    --platform) [ "$2" = linux/amd64 ]; shift 2 ;;
    --network) [ "$2" = none ]; shift 2 ;;
    --cap-drop) [ "$2" = ALL ]; shift 2 ;;
    --security-opt) [ "$2" = no-new-privileges ]; shift 2 ;;
    --user) [ "$2" = "$(id -u):$(id -g)" ]; shift 2 ;;
    --workdir) [ "$2" = /admin ] || [ "$2" = /conf/vs ]; shift 2 ;;
    --mount)
      mount=$2
      case "$mount" in
        type=bind,source="$TEST_ROOT"/*/conf/vs,target=/conf/vs)
          conf=${mount#type=bind,source=}; conf=${conf%,target=/conf/vs} ;;
        type=bind,source="$TEST_ROOT"/*/admin,target=/admin)
          admin=${mount#type=bind,source=}; admin=${admin%,target=/admin} ;;
        type=bind,source="$TEST_ROOT"/*/include/*-public-key.pem,target=/include/*-public-key.pem,readonly)
          source=${mount#type=bind,source=}; source=${source%%,target=*}
          name=${source##*/}
          [ "$mount" = "type=bind,source=$source,target=/include/$name,readonly" ]
          [ -s "$source" ]
          identities=${source%/*} ;;
        *) exit 91 ;;
      esac
      shift 2 ;;
    --entrypoint) program=$2; shift 2 ;;
    sha256:*) [ "$1" = "$(printf 'sha256:%064d' 1)" ]; shift; break ;;
    *) exit 92 ;;
  esac
done
case "$program" in
  /app/bin/vsapikey)
    [ -n "$conf" ] && [ -z "$admin$identities" ]
    [ "$1" = create ]; shift
    if [ "${1:-}" = --init ]; then
      [ ! -e "$conf/vs_keys.toml" ]; shift
      printf 'harmless mock API store, not a real credential\n' > "$conf/vs_keys.toml"
    else
      [ -s "$conf/vs_keys.toml" ]
    fi
    [ "$#" = 3 ] && [ "$3" = /conf/vs/vs_keys.toml ]
    case "$1:$2" in readwrite:client|read:web-monitor) ;; *) exit 93 ;; esac
    printf 'harmless mock API output for %s\n' "$2" ;;
  /app/bin/zplc)
    [ -z "$conf" ] && [ -n "$admin" ] && [ -n "$identities" ]
    [ "$*" = '--config multinode-demo.zplc multinode-demo.zpl' ]
    [ -s "$admin/multinode-demo.zpl" ] && [ -s "$identities/node0-public-key.pem" ]
    grep -q '"../include/node0-public-key.pem"' "$admin/multinode-demo.zplc"
    printf 'harmless mock compiled policy\n' > "$admin/multinode-demo.bin2" ;;
  *) exit 94 ;;
esac
EOF
chmod 700 "$TEMP/commands/docker"
export PATH="$TEMP/commands:$PATH"
INIT="$TEMP/package/runtime/init-demo-identities.sh"
cd "$TEMP/unrelated"

reject() {
  local state=$1
  if "$INIT" prepare "$state" > "$TEMP/output" 2> "$TEMP/diagnostics"; then
    fail "unsafe state or input was accepted"
  fi
  [ -s "$TEMP/diagnostics" ] || fail "rejection had no diagnostic"
}

reject relative
reject "$TEMP/state/../escape"
reject "$TEMP/state/"
mkdir -m 700 "$TEMP/partial"
printf 'incomplete\n' > "$TEMP/partial/leftover"
reject "$TEMP/partial"
[ "$(cat "$TEMP/partial/leftover")" = incomplete ] || fail "partial state was changed"
mkdir -m 700 "$TEMP/weak"
chmod 755 "$TEMP/weak"
reject "$TEMP/weak"
ln -s "$TEMP/partial" "$TEMP/link"
reject "$TEMP/link"
reject "$TEMP/link/child"

# Exercise the production guard before bypassing it only in the isolated test
# copy: Bash 3.2 can test orchestration, not the real helper's Bash 4.1 syntax.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 1) )); then
  reject "$TEMP/guard-state"
  grep -q 'Bash 4.1' "$TEMP/diagnostics" || fail "production shell guard was not enforced"
fi
sed 's/^(( BASH_VERSINFO.* ||$/true ||/' "$INIT" > "$TEMP/mock-initializer"
mv "$TEMP/mock-initializer" "$INIT"
chmod 700 "$INIT"
package_files=$(find "$TEMP/package" -type f | wc -l | tr -d ' ')
"$INIT" prepare "$TEMP/state"
[ "$(wc -l < "$TEST_DOCKER_LOG" | tr -d ' ')" = 3 ] || fail "expected exactly three isolated tool commands"
[ -s "$TEMP/state/.zpr-demo-state-v1" ] || fail "complete-state marker missing"
cp "$TEMP/state/.zpr-demo-state-v1" "$TEMP/original-inventory"
for identity in alice bob node0 node1 vs web0 web1; do
  openssl pkey -in "$TEMP/state/include/$identity-private-key.pem" -pubout \
    > "$TEMP/public-check" 2>/dev/null
  cmp "$TEMP/public-check" "$TEMP/state/include/$identity-public-key.pem" ||
    fail "RSA public/private binding mismatch"
done
for identity in node0 node1 vs; do
  "$TEMP/package/runtime/zpr-pki" pubkey < "$TEMP/state/include/$identity-noise.key" \
    > "$TEMP/public-check" 2>/dev/null
  cmp "$TEMP/public-check" "$TEMP/state/include/$identity-noise-pub.pem"
done
cmp "$TEMP/state/admin/multinode-demo.bin2" "$TEMP/state/conf/vs/multinode-demo.bin2"
grep -q 'node_public_key_file = "include/node1-noise-pub.pem"' \
  "$TEMP/state/conf/alice/adapter-alice-conf.toml"
for config in "$TEMP/state/conf/"*/*.toml "$TEMP/state/bob/adapter-bob-conf.toml"; do
  while IFS= read -r reference; do
    [ -s "$TEMP/state/$reference" ] || fail "config has a missing shared include reference"
  done < <(sed -n 's/.*"\(include\/[^"]*\)".*/\1/p' "$config")
done
[ ! -e "$TEMP/package/include" ] || fail "generated state escaped into the package"
[ "$(find "$TEMP/package" -type f | wc -l | tr -d ' ')" = "$package_files" ] || fail "package assets were changed"
[ -z "$(find "$TEMP/state" -type l)" ] || fail "generated state contains symlinks"
if stat -c '%a' "$TEMP/state" >/dev/null 2>&1; then
  [ -z "$(find "$TEMP/state" -type d ! -perm 0700 -print)" ] || fail "directory mode is not private"
  [ -z "$(find "$TEMP/state" -type f ! -perm 0600 -print)" ] || fail "file mode is not private"
else
  [ -z "$(find "$TEMP/state" -type d ! -perm 700 -print)" ] || fail "directory mode is not private"
  [ -z "$(find "$TEMP/state" -type f ! -perm 600 -print)" ] || fail "file mode is not private"
fi

mkdir -m 700 "$TEMP/root-commands"
cat > "$TEMP/root-commands/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -u|-g) printf '0\n' ;;
  *) exec /usr/bin/id "$@" ;;
esac
EOF
cat > "$TEMP/root-commands/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "$3" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
info = os.stat(path)
owner = info.st_uid
state_root = os.environ["TEST_ROOT_STATE"]
if path == state_root or path.startswith(state_root + os.sep):
    owner = 0
elif path == os.environ["TEST_FAKE_ANCESTOR"]:
    owner = 1000
elif owner == int(os.environ["TEST_REAL_UID"]) and owner != 0:
    owner = 1000
print(owner, format(stat.S_IMODE(info.st_mode), "o"), info.st_nlink)
PY
EOF
chmod 700 "$TEMP/root-commands/id" "$TEMP/root-commands/stat"
TEST_REAL_UID=$(id -u)
ROOT_TEST_PATH="$TEMP/root-commands:$PATH"
SUDO_STATE="$TEMP/sudo-state"
cp "$TEST_DOCKER_LOG" "$TEMP/docker-log-before-root-test"
env PATH="$ROOT_TEST_PATH" TEST_REAL_UID="$TEST_REAL_UID" TEST_FAKE_ANCESTOR="$TEMP" \
  TEST_ROOT_STATE="$SUDO_STATE" SUDO_UID=1000 \
  "$INIT" prepare "$SUDO_STATE" > "$TEMP/output" 2> "$TEMP/diagnostics" ||
  { cat "$TEMP/diagnostics" >&2; fail "sudo-owned state ancestors were rejected"; }
[ -s "$SUDO_STATE/.zpr-demo-state-v1" ] || fail "sudo-owned ancestor test did not create complete isolated state"
NO_SUDO_STATE="$TEMP/no-sudo-state"
if env PATH="$ROOT_TEST_PATH" TEST_REAL_UID="$TEST_REAL_UID" TEST_FAKE_ANCESTOR="$TEMP" \
  TEST_ROOT_STATE="$NO_SUDO_STATE" SUDO_UID= \
  "$INIT" prepare "$NO_SUDO_STATE" > "$TEMP/output" 2> "$TEMP/diagnostics"; then
  fail "root preparation accepted a non-root-owned ancestor without SUDO_UID"
fi
grep -q 'state ancestors must be owned by root, the invoking user, or the sudo user' "$TEMP/diagnostics" ||
  fail "missing SUDO_UID rejection did not identify the state ancestor"
[ ! -e "$NO_SUDO_STATE" ] || fail "rejected state path was created"
INVALID_SUDO_STATE="$TEMP/invalid-sudo-state"
if env PATH="$ROOT_TEST_PATH" TEST_REAL_UID="$TEST_REAL_UID" TEST_FAKE_ANCESTOR="$TEMP" \
  TEST_ROOT_STATE="$INVALID_SUDO_STATE" SUDO_UID=invalid \
  "$INIT" prepare "$INVALID_SUDO_STATE" > "$TEMP/output" 2> "$TEMP/diagnostics"; then
  fail "root preparation accepted a noncanonical SUDO_UID"
fi
grep -q 'SUDO_UID must be a canonical non-negative user ID' "$TEMP/diagnostics" ||
  fail "invalid SUDO_UID was not rejected explicitly"
[ ! -e "$INVALID_SUDO_STATE" ] || fail "invalid SUDO_UID path was created"
cp "$TEMP/docker-log-before-root-test" "$TEST_DOCKER_LOG"

# A complete rerun must not even require package helper/image assets or Docker.
mv "$TEMP/package/runtime/zpr-pki" "$TEMP/pki-away"
mv "$TEMP/package/runtime/image-reference" "$TEMP/image-away"
cat > "$TEMP/commands/docker" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected-tool\n' >> "$TEST_DOCKER_LOG"
exit 95
EOF
"$INIT" prepare "$TEMP/state"
cmp "$TEMP/original-inventory" "$TEMP/state/.zpr-demo-state-v1"
[ "$(wc -l < "$TEST_DOCKER_LOG" | tr -d ' ')" = 3 ] || fail "rerun invoked a tool container"

# Service-owned mutable data can be empty and readable within private roots.
mkdir -m 755 "$TEMP/state/state/redis/appendonlydir"
: > "$TEMP/state/logs/empty.log"
printf 'mock persistence\n' > "$TEMP/state/state/redis/appendonlydir/appendonly.aof"
chmod 644 "$TEMP/state/logs/empty.log" "$TEMP/state/state/redis/appendonlydir/appendonly.aof"
"$INIT" prepare "$TEMP/state"
cmp "$TEMP/original-inventory" "$TEMP/state/.zpr-demo-state-v1"
chmod 666 "$TEMP/state/logs/empty.log"
reject "$TEMP/state"
grep -q 'logs/empty.log' "$TEMP/diagnostics" || fail "diagnostic omitted mutable file path"
chmod 644 "$TEMP/state/logs/empty.log"
ln "$TEMP/state/logs/empty.log" "$TEMP/runtime-hardlink"
reject "$TEMP/state"
rm "$TEMP/runtime-hardlink"
ln -s "$TEMP/original-inventory" "$TEMP/state/logs/link.log"
reject "$TEMP/state"
rm "$TEMP/state/logs/link.log"
"$INIT" prepare "$TEMP/state"

printf 'mock marker\n' > "$TEMP/state/state/redis/.zpr-demo-policy-v1"
chmod 644 "$TEMP/state/state/redis/.zpr-demo-policy-v1"
reject "$TEMP/state"
grep -q '.zpr-demo-policy-v1' "$TEMP/diagnostics" || fail "diagnostic omitted policy marker path"
rm "$TEMP/state/state/redis/.zpr-demo-policy-v1"

printf 'tampered\n' >> "$TEMP/state/include/alice-private-key.pem"
reject "$TEMP/state"
cp "$TEMP/state/include/bob-private-key.pem" "$TEMP/bob-backup"
chmod 644 "$TEMP/state/include/bob-private-key.pem"
reject "$TEMP/state"
chmod 600 "$TEMP/state/include/bob-private-key.pem"
mv "$TEMP/state/include/bob-private-key.pem" "$TEMP/bob-saved"
ln -s "$TEMP/bob-backup" "$TEMP/state/include/bob-private-key.pem"
reject "$TEMP/state"
rm "$TEMP/state/include/bob-private-key.pem"
mv "$TEMP/bob-saved" "$TEMP/state/include/bob-private-key.pem"
ln "$TEMP/state/include/bob-private-key.pem" "$TEMP/extra-hardlink"
reject "$TEMP/state"
rm "$TEMP/extra-hardlink"
rm "$TEMP/state/include/bob-public-key.pem"
reject "$TEMP/state"

printf 'PASS: isolated generation, private modes, references, stable rerun and unsafe-state rejection; PKI/Docker mocked, real-helper crypto unverified.\n'

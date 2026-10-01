#!/usr/bin/env bash
# Configure + run ZPR in the local docker env (PLAN.md §5-8). Implements
# docker-configure-run-zpr.md. Mirrors oci-compute/deploy-zpr.sh, but the infra
# is owned by docker-compose.yml — this script does the dynamic host-side parts:
# render @@...@@ templates, generate vs_keys.toml, compile the policy, bring the
# containers up, then launch the ZPR processes in §8 order via `docker exec`.
#
#   ./deploy-docker.sh                       # same-host operator (node1 ext = 127.0.0.1)
#   NODE1_EXT_ADDR=203.0.113.7 ./deploy-docker.sh   # cross-host operator
#
# Re-runnable: re-renders/recompiles every run, kills old tmux sessions first.
# Needs the image built (`docker build -t zpr-multinode .` in ..) and a live
# ../oci-compute apply (for node0's public IP, baked into the policy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
MULTI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$MULTI_DIR/bin"
CONF_TMPL="$MULTI_DIR/zpr-conf/confs"
INC_DIR="$MULTI_DIR/zpr-conf/include"
ADMIN="$MULTI_DIR/zpr-conf/admin"
OCI_DIR="$MULTI_DIR/oci-compute"
COMPOSE=(docker compose -f "$MULTI_DIR/docker-compose.yml")

CONF_ROOT="$SCRIPT_DIR/conf"        # per-container /conf mounts
BOB_DIR="$SCRIPT_DIR/bob"        # bob = host-side operator client (not a container)
LOGS_DIR="$SCRIPT_DIR/logs"

# --- Step 0: addresses ---
NODE1_ADDR="172.30.0.10"                       # node1's docker-internal static IP (compose)
NODE1_EXT_ADDR="${NODE1_EXT_ADDR:-127.0.0.1}"  # node1 as reached from outside docker
NODE0_PUB="$(tofu -chdir="$OCI_DIR" output -json public_ips 2>/dev/null | jq -r '.node // empty')"
[ -n "$NODE0_PUB" ] || { echo "ERROR: no node0 public IP from '$OCI_DIR' tofu output — is ../oci-compute applied?" >&2; exit 1; }
echo "node1 internal=$NODE1_ADDR ext=$NODE1_EXT_ADDR ; node0 public=$NODE0_PUB"

# --- render: sub all three tokens, fail loud on any leftover @@...@@ ---
render() {  # $1=template path  $2=output path
  sed -e "s#@@NODE1_ADDR@@#${NODE1_ADDR}#g" \
      -e "s#@@NODE1_EXT_ADDR@@#${NODE1_EXT_ADDR}#g" \
      -e "s#@@NODE0_PUBLIC_ADDR@@#${NODE0_PUB}#g" \
      "$1" > "$2"
  if grep -n '@@[A-Z0-9_]*@@' "$2"; then
    echo "ERROR: unresolved template token(s) above in $(basename "$2")" >&2
    exit 1
  fi
}

# --- Step 1: assemble per-container /conf dirs (rendered config + whole include/) ---
rm -rf "$CONF_ROOT"
mkdir -p "$CONF_ROOT"/{node1,vs,web1} "$BOB_DIR" "$LOGS_DIR"
for c in node1 vs web1; do cp -r "$INC_DIR" "$CONF_ROOT/$c/include"; done  # ponytail: whole include/, small key files

cp "$CONF_TMPL/node1-conf.toml"        "$CONF_ROOT/node1/node1-conf.toml"    # no sentinel
render "$CONF_TMPL/adapter-vs-conf.toml.template"   "$CONF_ROOT/vs/adapter-vs-conf.toml"
render "$CONF_TMPL/adapter-web1-conf.toml.template" "$CONF_ROOT/web1/adapter-web1-conf.toml"
cp "$SCRIPT_DIR/vs.toml" "$CONF_ROOT/vs/vs.toml"
cp "$ADMIN/attrfile.json" "$CONF_ROOT/vs/attrfile.json"   # policy attributes, read by vs
cp "$CONF_TMPL/zpr-dashboard-config.toml" "$CONF_ROOT/vs/config.toml"  # zpr-dashboard reads ./config.toml

# bob, the host-side operator client (stays on host, next to client.key)
render "$CONF_TMPL/adapter-bob-conf.toml.template" "$BOB_DIR/adapter-bob-conf.toml"
ln -sfn "$INC_DIR" "$BOB_DIR/include"

# --- Step 2 (§7.3): vs_keys.toml + client.key ---
rm -f "$CONF_ROOT/vs/vs_keys.toml"
"$BIN_DIR/vsapikey" create --init readwrite client "$CONF_ROOT/vs/vs_keys.toml" > "$BOB_DIR/client.key"
"$BIN_DIR/vsapikey" create read web-monitor "$CONF_ROOT/vs/vs_keys.toml" > "$BOB_DIR/web-monitor.key"
chmod 600 "$BOB_DIR/client.key" "$BOB_DIR/web-monitor.key"
echo "operator key written to $BOB_DIR/client.key"
echo "read-only monitor key written to $BOB_DIR/web-monitor.key"

# --- Step 3: compile policy on host (needs ../include keys the .zplc references) ---
render "$ADMIN/multinode-demo.zplc.template" "$ADMIN/multinode-demo.zplc"
( cd "$ADMIN" && "$BIN_DIR/zplc" --config multinode-demo.zplc multinode-demo.zpl )
mv "$ADMIN/multinode-demo.bin2" "$CONF_ROOT/vs/multinode-demo.bin2"

# --- Step 4: bring up infra (entrypoints set up tun9 / valkey / nginx) ---
"${COMPOSE[@]}" up -d
sleep 2

# --- Step 5: launch ZPR in §8 order, each in a detached tmux, tee'd to /logs ---
# tee to a mounted /logs file so output survives the tmux session dying.
launch() {  # $1=container $2=session/logname $3=command(run with cwd /conf)
  docker exec "$1" tmux kill-session -t "$2" 2>/dev/null || true
  docker exec "$1" tmux new-session -d -s "$2" -c /conf "$3 2>&1 | tee /logs/$2.log"
  sleep 1
  docker exec "$1" tmux has-session -t "$2" 2>/dev/null \
    && echo "[$1] $2 running in tmux" \
    || { echo "ERROR: $2 exited immediately in $1 — see $LOGS_DIR/$2.log" >&2; exit 1; }
}

launch node1 node1 "/app/bin/ph node -c node1-conf.toml"
sleep 4
launch vs vs "/app/bin/vs --clear-state multinode-demo.bin2"
launch vs vs-adapter "/app/bin/ph adapter -c adapter-vs-conf.toml"
sleep 6

docker exec web1 curl -fsS http://localhost:80 >/dev/null \
  && echo "[web1] nginx serving :80" \
  || { echo "ERROR: nginx not serving in web1" >&2; exit 1; }
launch web1 web1-adapter "/app/bin/ph adapter -c adapter-web1-conf.toml"

cat <<EOF

Done. Local ZPR env is up.
  Logs:   tail -f $LOGS_DIR/*.log
  Attach: docker exec -it <node1|vs|web1> tmux attach -t <session>   (Ctrl-b d to detach)
  bob:    adapter config + key on host at $BOB_DIR/
  Teardown: ${COMPOSE[*]} down
EOF

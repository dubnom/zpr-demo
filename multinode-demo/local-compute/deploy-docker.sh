#!/usr/bin/env bash
# Configure + run ZPR in the local docker env (PLAN.md §5-8). Implements
# docker-configure-run-zpr.md. Mirrors oci-compute/deploy-zpr.sh, but the infra
# is owned by docker-compose.yml — this script does the dynamic host-side parts:
# render @@...@@ templates, generate vs_keys.toml, compile the policy, bring the
# containers up, then launch the two-node ZPR network in order via `docker exec`.
#
#   ./deploy-docker.sh
#
# Re-runnable: re-renders/recompiles every run, kills old tmux sessions first.
# Needs the Linux image built (`docker build --platform linux/amd64 -t zpr-multinode .` in ..).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
MULTI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$MULTI_DIR/bin"
CONF_TMPL="$MULTI_DIR/zpr-conf/confs"
INC_DIR="$MULTI_DIR/zpr-conf/include"
ADMIN="$MULTI_DIR/zpr-conf/admin"
COMPOSE=(docker compose -f "$MULTI_DIR/docker-compose.yml")

CONF_ROOT="$SCRIPT_DIR/conf"        # per-container /conf mounts
BOB_DIR="$SCRIPT_DIR/bob"        # bob = host-side operator client (not a container)
LOGS_DIR="$SCRIPT_DIR/logs"

# --- Step 0: static substrate addresses from docker-compose.yml ---
NODE0_ADDR="172.30.0.13"
NODE1_ADDR="172.30.0.10"
NODE1_EXT_ADDR="${NODE1_EXT_ADDR:-127.0.0.1}" # host-side bob adapter only
PEER_LINK_WAIT_SECONDS="${PEER_LINK_WAIT_SECONDS:-180}"
echo "node0=$NODE0_ADDR ; node1=$NODE1_ADDR ; host adapter node1=$NODE1_EXT_ADDR"

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

# --- Step 1: assemble per-container /conf dirs (rendered config + whole include/) ---
rm -rf "$CONF_ROOT"
mkdir -p "$CONF_ROOT"/{node0,node1,vs,web0,web1,alice} "$BOB_DIR" "$LOGS_DIR"
for c in node0 node1 vs web0 web1 alice; do cp -r "$INC_DIR" "$CONF_ROOT/$c/include"; done

cp "$CONF_TMPL/node0-conf.toml"        "$CONF_ROOT/node0/node0-conf.toml"
cp "$CONF_TMPL/node1-conf.toml"        "$CONF_ROOT/node1/node1-conf.toml"    # no sentinel
render "$CONF_TMPL/adapter-web0-conf.toml.template" "$CONF_ROOT/web0/adapter-web0-conf.toml"
render "$CONF_TMPL/adapter-vs-conf.toml.template"   "$CONF_ROOT/vs/adapter-vs-conf.toml"
render "$CONF_TMPL/adapter-web1-conf.toml.template" "$CONF_ROOT/web1/adapter-web1-conf.toml"
render "$CONF_TMPL/adapter-alice-local-conf.toml.template" "$CONF_ROOT/alice/adapter-alice-conf.toml"
cp "$SCRIPT_DIR/vs.toml" "$CONF_ROOT/vs/vs.toml"
cp "$ADMIN/attrfile.json" "$CONF_ROOT/vs/attrfile.json"   # policy attributes, read by vs
cp "$CONF_TMPL/zpr-dashboard-config.toml" "$CONF_ROOT/vs/config.toml"  # zpr-dashboard reads ./config.toml

# bob, the host-side operator client (stays on host, next to client.key)
render "$CONF_TMPL/adapter-bob-conf.toml.template" "$BOB_DIR/adapter-bob-conf.toml"
ln -sfn "$INC_DIR" "$BOB_DIR/include"

# --- Step 2 (§7.3): vs_keys.toml + client.key ---
rm -f "$CONF_ROOT/vs/vs_keys.toml"
docker run --rm --platform linux/amd64 -v "$CONF_ROOT/vs:/conf" zpr-multinode \
  /app/bin/vsapikey create --init readwrite client /conf/vs_keys.toml > "$BOB_DIR/client.key"
docker run --rm --platform linux/amd64 -v "$CONF_ROOT/vs:/conf" zpr-multinode \
  /app/bin/vsapikey create read web-monitor /conf/vs_keys.toml > "$BOB_DIR/web-monitor.key"
chmod 600 "$BOB_DIR/client.key" "$BOB_DIR/web-monitor.key"
echo "operator key written to $BOB_DIR/client.key"
echo "read-only monitor key written to $BOB_DIR/web-monitor.key"

# --- Step 3: compile policy on host (needs ../include keys the .zplc references) ---
render "$ADMIN/multinode-demo.zplc.template" "$ADMIN/multinode-demo.zplc"
docker run --rm --platform linux/amd64 \
  -v "$MULTI_DIR:/demo" -w /demo/zpr-conf/admin zpr-multinode \
  /app/bin/zplc --config multinode-demo.zplc multinode-demo.zpl
mv "$ADMIN/multinode-demo.bin2" "$CONF_ROOT/vs/multinode-demo.bin2"

# --- Step 4: bring up infra (entrypoints set up tun9 / valkey / nginx) ---
"${COMPOSE[@]}" up -d --force-recreate
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

wait_for_peer() { # $1=local node container $2=expected substrate address
  local summary
  echo "[$1] waiting for peer $2:5000 to become Active"
  for _ in $(seq "$((PEER_LINK_WAIT_SECONDS / 2))"); do
    summary=$(docker exec "$1" /app/bin/ph-cli -p /var/run/zpr/control.sock link show 2>/dev/null || true)
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
    summary=$(docker exec "$1" /app/bin/ph-cli -p /var/run/zpr/control.sock link show 2>/dev/null || true)
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

launch node0 node0 "/app/bin/ph node -c node0-conf.toml"
launch node1 node1 "/app/bin/ph node -c node1-conf.toml"
launch vs vs "/app/bin/vs --clear-state multinode-demo.bin2"
launch vs vs-adapter "/app/bin/ph adapter -c adapter-vs-conf.toml"

wait_for_peer node0 "$NODE1_ADDR"
wait_for_peer node1 "$NODE0_ADDR"

for container in web0 web1; do
  docker exec "$container" curl -fsS http://localhost:80 >/dev/null \
    && echo "[$container] nginx serving :80" \
    || { echo "ERROR: nginx not serving in $container" >&2; exit 1; }
done
launch web0 web0-adapter "env ZPR_ADAPTER_SERVICES=OciWeb /app/bin/ph adapter -c adapter-web0-conf.toml"
wait_for_adapter node0 172.30.0.14
if [[ "${START_PREMWEB_ADAPTER:-0}" == "1" ]]; then
  launch web1 web1-adapter "env ZPR_ADAPTER_SERVICES=PremWeb /app/bin/ph adapter -c adapter-web1-conf.toml"
  wait_for_adapter node1 172.30.0.12
else
  echo "[web1] PremWeb ZPR adapter skipped (set START_PREMWEB_ADAPTER=1 to enable)"
fi
launch alice alice-adapter "/app/bin/ph adapter -c adapter-alice-conf.toml"

echo "[alice] checking policy-authorized HTTP to OciWeb across the node peer"
alice_response=""
for _ in $(seq 20); do
  if alice_response=$(docker exec alice curl -g -6 -fsS --max-time 5 'http://[fd5a:5052:8888::8]/' 2>/dev/null); then
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

cat <<EOF

Done. Local two-node ZPR env is up.
  Logs:   tail -f $LOGS_DIR/*.log
  Attach: docker exec -it <node0|node1|vs|web0|web1|alice> tmux attach -t <session>   (Ctrl-b d to detach)
  bob:    adapter config + key on host at $BOB_DIR/
  Teardown: ${COMPOSE[*]} down
EOF

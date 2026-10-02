#!/usr/bin/env bash
# Deploy + run ZPR on the OCI hosts (PLAN.md §3 + §4). Implements
# tf-configure-run-zpr.md. Run after `tofu apply`, from anywhere:
#   ./deploy-zpr.sh
# Re-runnable: scp overwrites, ph is pkill'd before restart, addresses come
# straight from `tofu output`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # oci-compute/ = tofu root
MULTI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$MULTI_DIR/bin"
CONF_DIR="$MULTI_DIR/zpr-conf/confs"
INC_DIR="$MULTI_DIR/zpr-conf"        # include/… paths in configs are relative to here

KEY="${SSH_KEY:-$HOME/.ssh/zpr-demo}"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

tf()   { tofu -chdir="$SCRIPT_DIR" "$@"; }
ssh_h(){ ssh "${SSH_OPTS[@]}" "ubuntu@$1" "${@:2}"; }

# --- Step 0: addresses from tofu ---
NODE_PRIV=$(tf output -json private_ips | jq -r .node)
NODE_PUB=$(tf output -json public_ips   | jq -r .node)
WEB_PUB=$(tf output -json public_ips     | jq -r .webserver)
ALICE_PUB=$(tf output -json public_ips   | jq -r .alice)
NODE1_EXT_ADDR="${NODE1_EXT_ADDR:-}"
if [[ -z "$NODE1_EXT_ADDR" || ! "$NODE1_EXT_ADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$NODE1_EXT_ADDR" == 127.* ]]; then
  echo "ERROR: set NODE1_EXT_ADDR to node1's externally reachable IPv4 address" >&2
  exit 1
fi
echo "node priv=$NODE_PRIV pub=$NODE_PUB ; webserver pub=$WEB_PUB ; alice pub=$ALICE_PUB"

# tun9 sanity. Run straight after `tofu apply` and cloud-init may still be
# installing zpr-tun.service, so wait for it rather than failing the race.
check_tun9() {  # $1=pubip $2=label
  for _ in $(seq 60); do
    ssh_h "$1" "ip addr show tun9 >/dev/null 2>&1" && { echo "[$2] tun9 up"; return; }
    sleep 5
  done
  echo "ERROR: tun9 not up on $2 ($1) after 5min — check zpr-tun.service" >&2; exit 1
}

# --- Step 1: render *.toml.template -> scratch/*.toml, fail on leftover sentinel ---
render() {  # $1=template basename; echoes path to rendered file
  local out="$SCRATCH/${1%.template}"
  sed "s/@@NODE0_ADDR@@/${NODE_PRIV}/" "$CONF_DIR/$1" > "$out"
  if grep -n '@@[A-Z0-9_]*@@' "$out"; then
    echo "ERROR: unresolved template token(s) above in ${1%.template}" >&2
    exit 1
  fi
  echo "$out"
}

# --- Step 2: ph + one conf + only its referenced include files, + runtime dir ---
deploy_host() {  # $1=pubip $2=conf-path $3=label
  local ip="$1" conf="$2" label="$3"
  local -a inc
  mapfile -t inc < <(grep -oE 'include/[^"]+' "$conf" | sort -u)   # source of truth
  echo "[$label] deploying $(basename "$conf") + ${#inc[@]} include file(s)"
  ssh_h "$ip" "mkdir -p zpr/include"
  # ph is ~200 MB — skip the upload if the host already has the same-size binary.
  local sz; sz=$(stat -c%s "$BIN_DIR/ph")
  if ssh_h "$ip" "[ -x zpr/ph ] && [ \$(stat -c%s zpr/ph 2>/dev/null) = $sz ]"; then
    echo "[$label] ph already up-to-date, skipping binary upload"
  else
    # A running ph IS the destination file, so scp would fail with ETXTBSY. Stop it
    # first — start_ph brings it back moments later. sudo covers the alice host, where
    # ph runs as root. -x matches the process name, not the cmdline, so this cannot
    # match (and kill) our own ssh command.
    # pkill returns once the signal is SENT, so wait for the process to actually go:
    # scp'ing into a still-dying ph fails exactly the same way.
    ssh_h "$ip" "sudo pkill -x ph 2>/dev/null || true; \
      for _ in \$(seq 25); do pgrep -x ph >/dev/null || break; sleep 0.2; done; \
      pgrep -x ph >/dev/null && sudo pkill -9 -x ph && sleep 0.5; true"
    scp "${SSH_OPTS[@]}" "$BIN_DIR/ph" "ubuntu@$ip:zpr/"
  fi
  scp "${SSH_OPTS[@]}" "$conf" "ubuntu@$ip:zpr/"
  scp "${SSH_OPTS[@]}" "${inc[@]/#/$INC_DIR/}" "ubuntu@$ip:zpr/include/"
  scp "${SSH_OPTS[@]}" "$BIN_DIR/ph-cli" "ubuntu@$ip:zpr/"
  ssh_h "$ip" "chmod 755 ~/zpr/ph-cli"
  ssh_h "$ip" "sudo install -d -o ubuntu -g ubuntu /var/run/zpr"   # one sudo step
}

wait_for_node1_peer() {
  local summary
  echo "[node] waiting for node1 at $NODE1_EXT_ADDR:5000 to become Active"
  for _ in $(seq 90); do
    summary=$(ssh_h "$NODE_PUB" "~/zpr/ph-cli -p /var/run/zpr/control.sock link show" 2>/dev/null || true)
    if grep -Fq "$NODE1_EXT_ADDR:5000 (Active)" <<< "$summary"; then
      echo "[node] node1 peer link is Active"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: node1 peer link did not become Active within 180 seconds" >&2
  ssh_h "$NODE_PUB" "tail -n 80 ~/zpr/node.log" >&2 || true
  exit 1
}

# --- Step 3: start ph inside a detached tmux session so it can be attached to ---
# Session name = mode (one ph per host). Re-run kills the old session first.
# Attach to watch output: ssh -t ubuntu@<host> tmux attach -t <mode>
start_ph() {  # $1=pubip $2=mode(node|adapter) $3=conf-basename $4=label $5=cmd-prefix (e.g. "sudo ")
  # tee to ~/zpr/$mode.log so output survives the tmux session dying (^C, crash).
  # pkill before kill-session: a sudo'd ph is root, so tmux (as ubuntu) can't
  # signal it and the old one would survive the restart. Match the process NAME
  # (-x ph), not the cmdline: -f would also match this very command string
  # (it contains the ./ph launch line) and kill our own shell. One ph per host,
  # so an exact-name match is precise enough.
  ssh_h "$1" "${5:-}pkill -x ph 2>/dev/null || true; \
    tmux kill-session -t $2 2>/dev/null || true; \
    tmux new-session -d -s $2 -c ~/zpr '${5:-}./ph $2 -c ~/zpr/$3 2>&1 | tee ~/zpr/$2.log'; \
    sleep 1; tmux has-session -t $2 2>/dev/null \
      && echo '[$4] ph $2 running in tmux session \"$2\"' \
      || { echo 'ERROR: ph $2 exited immediately on $4' >&2; exit 1; }"
}

# =============================== run ===============================
check_tun9 "$NODE_PUB" node
check_tun9 "$WEB_PUB"  webserver

WEB_CONF=$(render adapter-web0-conf.toml.template)
ALICE_CONF=$(render adapter-alice-conf.toml.template)

# §4 step 2: node first.
deploy_host "$NODE_PUB" "$CONF_DIR/node0-conf.toml" node
start_ph    "$NODE_PUB" node node0-conf.toml node
wait_for_node1_peer

# §4 step 4: web service already up from cloud-init — just verify.
ssh_h "$WEB_PUB" "curl -fsS http://localhost:80 >/dev/null" \
  && echo "[webserver] nginx serving :80" \
  || { echo "ERROR: nginx not serving on webserver" >&2; exit 1; }

# §4 step 5: web adapter, pointed at the now-up node.
deploy_host "$WEB_PUB" "$WEB_CONF" webserver
start_ph    "$WEB_PUB" adapter adapter-web0-conf.toml webserver

# alice's adapter. Its config sets no tun_if (dynamic ZPR address), so ph
# creates its own TUN device and must run as root — hence the sudo prefix.
deploy_host "$ALICE_PUB" "$ALICE_CONF" alice
start_ph    "$ALICE_PUB" adapter adapter-alice-conf.toml alice "sudo "

# --- /etc/hosts for the demo web actors (work/hosts-files.md) ---
# The operator curls premweb.demo / ociweb.demo from this host. Both addresses
# are fixed by policy (zpr-conf/admin/multinode-demo.zplc.template), so there is
# nothing to derive — just plant them. Delete-then-append keeps a re-run from
# stacking duplicate lines.
ssh_h "$ALICE_PUB" "sudo sed -i '/ premweb\.demo\$/d;/ ociweb\.demo\$/d' /etc/hosts; \
  printf 'fd5a:5052:8888::9 premweb.demo\nfd5a:5052:8888::8 ociweb.demo\n' \
    | sudo tee -a /etc/hosts >/dev/null"
echo "[alice] /etc/hosts: premweb.demo, ociweb.demo"

# The banner-curl wrapper (work/fetcher.md). Standalone script, so this one scp is
# the whole install; lands in the login dir => `./fetch http://premweb.demo`.
scp "${SSH_OPTS[@]}" "$MULTI_DIR/commands/fetch" "$MULTI_DIR/tools/repeat.sh" "ubuntu@$ALICE_PUB:"
echo "[alice] ~/fetch, ~/repeat.sh installed"

echo
echo "Done. Attach to a ph session to watch its output (Ctrl-b d to detach):"
echo "  ssh -i $KEY -t ubuntu@$NODE_PUB  tmux attach -t node"
echo "  ssh -i $KEY -t ubuntu@$WEB_PUB   tmux attach -t adapter"
echo "  ssh -i $KEY -t ubuntu@$ALICE_PUB tmux attach -t adapter"
echo "Logs also tee'd to ~/zpr/<mode>.log on each host (survive the tmux session):"
echo "  ssh -i $KEY ubuntu@$NODE_PUB  'tail -f ~/zpr/node.log'"
echo "  ssh -i $KEY ubuntu@$WEB_PUB   'tail -f ~/zpr/adapter.log'"
echo "  ssh -i $KEY ubuntu@$ALICE_PUB 'tail -f ~/zpr/adapter.log'"
echo
echo "Alice host — ssh in and curl through ZPR:"
echo "  ssh -i $KEY ubuntu@$ALICE_PUB"

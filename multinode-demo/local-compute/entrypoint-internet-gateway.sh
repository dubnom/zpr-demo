#!/bin/sh
set -eu

: "${ZPR_GATEWAY_ALLOWED_HOSTS:?organization web gateway allowlist is required}"
: "${ZPR_GATEWAY_NODE_ADDRESS:?organization node address is required}"

mkdir -p /var/run/zpr
ip tuntap add name tun10 mode tun multi_queue
ip link set tun10 mtu 1400
ip link set tun10 up

substrate_address=$(ip -4 -o addr show dev eth0 | awk 'NR == 1 { split($4, value, "/"); print value[1]; exit }')
[ -n "$substrate_address" ] || { echo "gateway substrate address unavailable" >&2; exit 1; }

ZPR_ADAPTER_SERVICES=InternetGatewayWeb /app/bin/ph adapter \
  --logging all=INFO \
  --control-path /var/run/zpr/internet-gateway.sock \
  --capture-path /var/run/zpr/internet-gateway-cap.sock \
  --self-addr "$substrate_address" \
  --ca-file /conf/include/auth-ca.crt \
  --bootstrap-key /conf/internet-gateway-rsa.key \
  --name internet-gateway \
  --km-impl noise \
  --tun-if tun10 \
  --node-addr "$ZPR_GATEWAY_NODE_ADDRESS:5000" \
  >>/logs/internet-gateway-adapter.log 2>&1 &
adapter_pid=$!
gateway_pid=
cleanup() {
  [ -z "$gateway_pid" ] || kill "$gateway_pid" 2>/dev/null || true
  kill "$adapter_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

attempt=0
while [ "$attempt" -lt 90 ]; do
  if /app/bin/ph-cli -p /var/run/zpr/internet-gateway.sock link show 2>/dev/null | grep -q '(Active)'; then
    break
  fi
  if ! kill -0 "$adapter_pid" 2>/dev/null; then
    tail -n 80 /logs/internet-gateway-adapter.log >&2 || true
    echo "internet gateway adapter exited before connecting" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -ge 90 ]; then
  tail -n 80 /logs/internet-gateway-adapter.log >&2 || true
  echo "internet gateway adapter did not become active" >&2
  exit 1
fi
gateway_address=$(ip -6 -o addr show dev tun10 scope global | awk '$4 ~ /^fd5a:5052:adda:1:/ { split($4, address, "/"); print address[1]; exit }')
[ -n "$gateway_address" ] || { echo "Visa-assigned Gateway ZPR address unavailable" >&2; exit 1; }

/app/bin/zpr-web-dashboard \
  -mode web-gateway-service \
  -listen "[$gateway_address]:8082" \
  -log-workload internet-gateway \
  -gateway-allowed-hosts "$ZPR_GATEWAY_ALLOWED_HOSTS" \
  >>/logs/internet-gateway-service.log 2>&1 &
gateway_pid=$!

wait "$gateway_pid"
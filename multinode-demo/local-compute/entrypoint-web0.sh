#!/bin/sh
set -e

mkdir -p /var/run/zpr
ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:8888::8/32 dev tun9
ip link set tun9 up
/tools/regen-banner.sh OCIWEB /var/www/html/index.html &
nginx -g 'daemon off;' &
nginx_pid=$!

terminate() {
  trap - TERM INT
  if [ -n "$nginx_pid" ]; then
    kill -TERM "$nginx_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT

wait "$nginx_pid" || true
nginx_pid=
while :; do
  sleep 1
done
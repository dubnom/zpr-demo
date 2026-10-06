#!/bin/sh
set -eu

: "${ZPR_NODE_ZPR_ADDRESS:?ZPR node address is required}"
mkdir -p /var/run/zpr
ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add "$ZPR_NODE_ZPR_ADDRESS/32" dev tun9
ip link set tun9 up

exec sleep infinity
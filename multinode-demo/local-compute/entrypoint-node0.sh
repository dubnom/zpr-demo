#!/bin/sh
set -e

mkdir -p /var/run/zpr
ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:90de::10/32 dev tun9
ip link set tun9 up

exec sleep infinity
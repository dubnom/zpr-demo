#!/bin/sh
# vs: bring up tun9 (matches adapter-vs-conf.toml zpr_addr), start valkey, then idle.
# The `vs` and `ph adapter` processes are launched by deploy-docker.sh via `docker exec`.
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052::1/32 dev tun9
ip link set tun9 up

# Forward the HTTPS admin API from the ZPR-only interface to a host-loopback
# published port. The TLS session remains end to end between the host client
# and the Visa Service.
socat TCP-LISTEN:8183,bind=0.0.0.0,reuseaddr,fork TCP:[fd5a:5052::1]:8182 &

echo "starting valkey on 127.0.0.1:6379"
valkey-server --bind 127.0.0.1 --port 6379 &

exec sleep infinity

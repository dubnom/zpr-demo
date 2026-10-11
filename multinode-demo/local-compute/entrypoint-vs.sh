#!/bin/sh
# vs: bring up tun9 (matches adapter-vs-conf.toml zpr_addr), start Redis, then idle.
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
socat TCP-LISTEN:8183,reuseaddr,fork TCP:[fd5a:5052::1]:8182 &

echo "starting Redis on 127.0.0.1:6379"
mkdir -p /state
appendonly=yes
if [ -s /state/dump.rdb ] && [ ! -s /state/appendonlydir/appendonly.aof.manifest ]; then
    appendonly=no
fi
redis-server --bind 127.0.0.1 --port 6379 --protected-mode yes \
    --dir /state --save 60 1 --appendonly "$appendonly" --appendfsync always &
redis_pid=$!
attempt=0
until [ "$(redis-cli --raw PING 2>/dev/null)" = PONG ]; do
    if ! kill -0 "$redis_pid" 2>/dev/null || [ "$attempt" -ge 60 ]; then
        echo "persistent Visa database failed to start" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep 1
done
if [ "$appendonly" = no ]; then
    [ "$(redis-cli --raw CONFIG SET appendonly yes)" = OK ] || {
        echo "Visa database AOF migration failed" >&2; exit 1;
    }
    attempt=0
    until redis-cli --raw INFO persistence | tr -d '\r' | grep -qx 'aof_rewrite_in_progress:0'; do
        [ "$attempt" -lt 60 ] || { echo "Visa database AOF migration timed out" >&2; exit 1; }
        attempt=$((attempt + 1))
        sleep 1
    done
    redis-cli --raw INFO persistence | tr -d '\r' | grep -qx 'aof_last_bgrewrite_status:ok' || {
        echo "Visa database AOF migration failed" >&2; exit 1;
    }
fi

exec sleep infinity

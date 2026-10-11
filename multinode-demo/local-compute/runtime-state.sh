#!/usr/bin/env bash

copy_initial_include() {
  local source destination
  mkdir -p "$RUNTIME_ROOT/include"
  for source in "$INC_DIR"/*; do
    case "$(basename "$source")" in node*-*) continue ;; esac
    destination="$RUNTIME_ROOT/include/$(basename "$source")"
    if [ ! -e "$destination" ]; then cp "$source" "$destination"; fi
  done
  if ! openssl pkey -in "$RUNTIME_ROOT/include/auth-ca.key" -passin pass:secret -noout >/dev/null 2>&1; then
    echo "organization CA private key is unreadable" >&2
    return 1
  fi
  openssl pkey -in "$RUNTIME_ROOT/include/auth-ca.key" -passin pass:secret \
    -out "$RUNTIME_ROOT/include/auth-ca.key.tmp" >/dev/null 2>&1
  chmod 600 "$RUNTIME_ROOT/include/auth-ca.key.tmp"
  mv "$RUNTIME_ROOT/include/auth-ca.key.tmp" "$RUNTIME_ROOT/include/auth-ca.key"
}

ensure_node_identity() {
  local include=$1 index=$2 existing=0 suffix directory
  local -a suffixes=(private-key.pem public-key.pem noise.key noise-pub.pem noise.crt)
  for suffix in "${suffixes[@]}"; do
    if [ -e "$include/node$index-$suffix" ]; then
      [ -s "$include/node$index-$suffix" ] && [ ! -L "$include/node$index-$suffix" ] || {
        echo "invalid node$index identity file: $suffix" >&2; return 1;
      }
      existing=$((existing + 1))
    fi
  done
  if [ "$existing" -ne 0 ] && [ "$existing" -ne "${#suffixes[@]}" ]; then
    echo "incomplete node$index identity; refusing automatic key rotation" >&2
    return 1
  fi
  if [ "$existing" -eq 0 ]; then
    directory=$(mktemp -d "$include/.node$index.XXXXXX")
    if ! (
      umask 077
      openssl genrsa -out "$directory/private-key.pem" 2048 >/dev/null 2>&1 &&
      openssl rsa -in "$directory/private-key.pem" -pubout -out "$directory/public-key.pem" >/dev/null 2>&1 &&
      "$ZPR_PKI_BIN" genkey > "$directory/noise.key" &&
      "$ZPR_PKI_BIN" pubkey < "$directory/noise.key" > "$directory/noise-pub.pem" &&
      "$ZPR_PKI_BIN" gensignedcert "$include/auth-ca.crt" "$include/auth-ca.key" "/CN=node$index.demo" 365 \
        < "$directory/noise-pub.pem" > "$directory/noise.crt"
    ); then
      rm -rf "$directory"
      echo "node$index identity generation failed" >&2
      return 1
    fi
    for suffix in "${suffixes[@]}"; do mv "$directory/$suffix" "$include/node$index-$suffix"; done
    rmdir "$directory"
  fi
  if ! cmp -s <(openssl pkey -in "$include/node$index-private-key.pem" -pubout) "$include/node$index-public-key.pem" ||
     ! cmp -s <("$ZPR_PKI_BIN" pubkey < "$include/node$index-noise.key") "$include/node$index-noise-pub.pem" ||
     ! cmp -s <(openssl x509 -in "$include/node$index-noise.crt" -pubkey -noout) "$include/node$index-noise-pub.pem" ||
     ! openssl verify -CAfile "$include/auth-ca.crt" "$include/node$index-noise.crt" >/dev/null ||
     ! openssl x509 -in "$include/node$index-noise.crt" -noout -subject -nameopt RFC2253 | grep -qx "subject=CN=node$index.demo"; then
    echo "node$index identity binding is invalid; refusing automatic key rotation" >&2
    return 1
  fi
  chmod 600 "$include/node$index-private-key.pem" "$include/node$index-noise.key"
}

visa_start_command() {
  local policy_exists=$1
  case "$policy_exists:${ZPR_RESTORE_BASE:-0}" in
    1:0) printf '/app/bin/vs\n' ;;
    0:0)
      if [ "$existing_runtime" = yes ]; then
        echo "persisted Visa database has no active policy; refusing implicit reset" >&2
        return 1
      fi
      touch "$RUNTIME_ROOT/policy-bootstrap-required"
      printf '/app/bin/vs multinode-demo.bin2\n'
      ;;
    0:1|1:1)
      touch "$RUNTIME_ROOT/policy-bootstrap-required"
      printf '/app/bin/vs --clear-state multinode-demo.bin2\n'
      ;;
    *) echo "cannot determine persisted Visa policy state" >&2; return 1 ;;
  esac
}

wait_for_visa_lease() {
  local container=$1 attempt ttl
  for ((attempt = 0; attempt < 120; attempt++)); do
    ttl=$(docker exec "$container" redis-cli --raw PTTL lock:vsinstance)
    case "$ttl" in
      -2) return 0 ;;
      -1) echo "Visa instance lease has no expiry; refusing takeover" >&2; return 1 ;;
      ''|*[!0-9]*) echo "cannot read Visa instance lease" >&2; return 1 ;;
    esac
    sleep 1
  done
  echo "previous Visa instance lease did not expire; refusing takeover" >&2
  return 1
}

preserve_vs_database() {
  local container directory snapshot
  container=$(container_name vs)
  if ! docker inspect "$container" >/dev/null 2>&1; then return 0; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
    [ -s "$RUNTIME_ROOT/state/redis/dump.rdb" ] || [ -s "$RUNTIME_ROOT/state/redis/appendonlydir/appendonly.aof.manifest" ] || {
      echo "Visa database is not persisted; start $container before redeploying" >&2; return 1;
    }
    return 0
  fi
  directory=$(docker exec "$container" redis-cli --raw CONFIG GET dir | tail -n 1)
  if [ "$directory" = /state ]; then
    [ "$(docker exec "$container" redis-cli --raw SAVE)" = OK ] || {
      echo "Visa database checkpoint failed" >&2; return 1;
    }
  else
    mkdir -p "$RUNTIME_ROOT/state/redis"
    snapshot=$(mktemp "$RUNTIME_ROOT/state/redis/.snapshot.XXXXXX")
    if ! docker exec "$container" redis-cli --rdb /tmp/zpr-recovery.rdb >/dev/null ||
       ! docker cp "$container:/tmp/zpr-recovery.rdb" "$snapshot" ||
       [ ! -s "$snapshot" ]; then
      rm -f "$snapshot"
      echo "Visa database migration failed; runtime not stopped" >&2
      return 1
    fi
    chmod 600 "$snapshot"
    mv "$snapshot" "$RUNTIME_ROOT/state/redis/dump.rdb"
    docker exec "$container" rm -f /tmp/zpr-recovery.rdb
  fi
}

ensure_api_credentials() {
  local file existing=0
  for file in "$CONF_ROOT/vs/vs_keys.toml" "$BOB_DIR/client.key" "$BOB_DIR/web-monitor.key"; do
    if [ -e "$file" ]; then
      [ -s "$file" ] && [ ! -L "$file" ] || { echo "invalid API credential: $file" >&2; return 1; }
      existing=$((existing + 1))
    fi
  done
  if [ "$existing" -eq 3 ]; then return 0; fi
  if [ "$existing" -ne 0 ]; then
    echo "incomplete Visa API credentials; refusing automatic credential rotation" >&2
    return 1
  fi
  docker run --rm --platform linux/amd64 -v "$CONF_ROOT/vs:/conf" zpr-multinode \
    /app/bin/vsapikey create --init readwrite client /conf/vs_keys.toml > "$BOB_DIR/client.key"
  docker run --rm --platform linux/amd64 -v "$CONF_ROOT/vs:/conf" zpr-multinode \
    /app/bin/vsapikey create read web-monitor /conf/vs_keys.toml > "$BOB_DIR/web-monitor.key"
  chmod 600 "$CONF_ROOT/vs/vs_keys.toml" "$BOB_DIR/client.key" "$BOB_DIR/web-monitor.key"
}

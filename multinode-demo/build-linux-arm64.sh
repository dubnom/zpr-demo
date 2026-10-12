#!/usr/bin/env bash
set -euo pipefail

: "${ZPR_ROOT:?ZPR_ROOT must be set to the mounted ZPR workspace}"
[ "$(uname -s)" = Linux ] || { echo "Linux infrastructure must be built in a Linux builder" >&2; exit 1; }
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "ARM64 infrastructure must be built in a native ARM64 builder" >&2; exit 1 ;;
esac
BIN_DIR="$ZPR_ROOT/zpr-demo/multinode-demo/bin/linux-arm64"
mkdir -p "$BIN_DIR"

bash "$ZPR_ROOT/zpr-demo/multinode-demo/build-linux-arm64-machine-tools.sh"
cp "$ZPR_ROOT/zpr-core/target/linux-arm64-machine-tools/release/ph" \
   "$ZPR_ROOT/zpr-core/target/linux-arm64-machine-tools/release/ph-cli" "$BIN_DIR/"

export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-visaservice/target/linux-arm64"
cargo build --locked --manifest-path "$ZPR_ROOT/zpr-visaservice/Cargo.toml" --release
cp "$CARGO_TARGET_DIR/release/vs" "$CARGO_TARGET_DIR/release/vs-admin" \
   "$CARGO_TARGET_DIR/release/vsapikey" "$BIN_DIR/"

export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-compiler/target/linux-arm64"
cargo build --locked --manifest-path "$ZPR_ROOT/zpr-compiler/Cargo.toml" --release
cp "$CARGO_TARGET_DIR/release/zplc" "$CARGO_TARGET_DIR/release/zpdump" "$BIN_DIR/"

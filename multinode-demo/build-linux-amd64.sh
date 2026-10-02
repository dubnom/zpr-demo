#!/usr/bin/env bash
set -euo pipefail

: "${ZPR_ROOT:?ZPR_ROOT must be set to the mounted ZPR workspace}"
MULTI_DIR="$ZPR_ROOT/zpr-demo/multinode-demo"
mkdir -p "$MULTI_DIR/bin"

export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-core/target/linux-amd64"
cargo build --manifest-path "$ZPR_ROOT/zpr-core/adapter/ph/Cargo.toml" --release
cargo build --manifest-path "$ZPR_ROOT/zpr-core/adapter/cli/Cargo.toml" --release
cp "$CARGO_TARGET_DIR/release/ph" "$CARGO_TARGET_DIR/release/ph-cli" "$MULTI_DIR/bin/"

export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-visaservice/target/linux-amd64"
cargo build --manifest-path "$ZPR_ROOT/zpr-visaservice/Cargo.toml" --release
cp "$CARGO_TARGET_DIR/release/vs" "$CARGO_TARGET_DIR/release/vs-admin" "$CARGO_TARGET_DIR/release/vsapikey" "$MULTI_DIR/bin/"

export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-compiler/target/linux-amd64"
cargo build --manifest-path "$ZPR_ROOT/zpr-compiler/Cargo.toml" --release
cp "$CARGO_TARGET_DIR/release/zplc" "$CARGO_TARGET_DIR/release/zpdump" "$MULTI_DIR/bin/"
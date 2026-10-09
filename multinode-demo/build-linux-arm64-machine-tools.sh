#!/usr/bin/env bash
set -euo pipefail

: "${ZPR_ROOT:?ZPR_ROOT must be set to the mounted ZPR workspace}"
export CARGO_TARGET_DIR="$ZPR_ROOT/zpr-core/target/linux-arm64-machine-tools"

cargo build --manifest-path "$ZPR_ROOT/zpr-core/adapter/ph/Cargo.toml" --release
cargo build --manifest-path "$ZPR_ROOT/zpr-core/adapter/cli/Cargo.toml" --release
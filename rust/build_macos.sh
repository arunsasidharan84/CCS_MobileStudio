#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT_DIR/rust/Cargo.toml"
BUILD_MODE="${1:-release}"

if [[ "$BUILD_MODE" == "debug" ]]; then
  CARGO_FLAGS=()
  PROFILE_DIR="debug"
else
  CARGO_FLAGS=(--release)
  PROFILE_DIR="release"
fi

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
for TARGET in "${TARGETS[@]}"; do
  cargo build \
    --manifest-path "$MANIFEST" \
    --target "$TARGET" \
    "${CARGO_FLAGS[@]}"
done

OUTPUT_DIR="$ROOT_DIR/rust/target/macos-universal/$PROFILE_DIR"
mkdir -p "$OUTPUT_DIR"
lipo -create \
  "$ROOT_DIR/rust/target/aarch64-apple-darwin/$PROFILE_DIR/libtrain_nidra_core.dylib" \
  "$ROOT_DIR/rust/target/x86_64-apple-darwin/$PROFILE_DIR/libtrain_nidra_core.dylib" \
  -output "$OUTPUT_DIR/libtrain_nidra_core.dylib"

echo "$OUTPUT_DIR/libtrain_nidra_core.dylib"

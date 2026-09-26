#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust"
JNI_DIR="$ROOT_DIR/android/app/src/main/jniLibs"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
NDK_HOME="${NDK_HOME:-$ANDROID_SDK_ROOT/ndk/28.2.13676358}"
case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;
  Linux) HOST_TAG="linux-x86_64" ;;
  *) echo "Unsupported Android build host: $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN_BIN="$NDK_HOME/toolchains/llvm/prebuilt/$HOST_TAG/bin"
API="${ANDROID_API:-24}"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"

if [[ ! -x "$CARGO" ]]; then
  echo "cargo not found at $CARGO" >&2
  exit 1
fi

build_one() {
  local target="$1"
  local abi="$2"
  local clang="$3"
  local target_env
  target_env="$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')"
  local linker_var="CARGO_TARGET_${target_env}_LINKER"
  mkdir -p "$JNI_DIR/$abi"
  (
    cd "$RUST_DIR"
    env "$linker_var=$TOOLCHAIN_BIN/$clang" \
      CC="$TOOLCHAIN_BIN/$clang" \
      AR="$TOOLCHAIN_BIN/llvm-ar" \
      "$CARGO" build --release --target "$target"
  )
  cp "$RUST_DIR/target/$target/release/libtrain_nidra_core.so" "$JNI_DIR/$abi/libtrain_nidra_core.so"
}

build_one "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android${API}-clang"
build_one "armv7-linux-androideabi" "armeabi-v7a" "armv7a-linux-androideabi${API}-clang"
build_one "x86_64-linux-android" "x86_64" "x86_64-linux-android${API}-clang"

echo "Android Rust libraries copied to $JNI_DIR"

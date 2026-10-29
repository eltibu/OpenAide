#!/usr/bin/env bash
# Builds the encrypted chat library (native/encryption, the web's own MLS
# code) for the phone and/or this computer.
#
#   tool/build_encryption.sh android   # into android/app/src/main/jniLibs
#   tool/build_encryption.sh host      # for the tests; prints the library
#
# Installs Rust (rustup, in your home folder) the first time. The build
# output is kept in ~/.cache/openaide-cargo-target between runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain none >&2
fi
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/openaide-cargo-target}"
cd "$ROOT/native/encryption"

for what in "$@"; do
  case "$what" in
    android)
      SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
      NDK="$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1 || true)"
      if [ -z "$NDK" ]; then
        SDKMANAGER="$(ls "$SDK"/cmdline-tools/*/bin/sdkmanager 2>/dev/null | head -1)"
        yes | "$SDKMANAGER" "ndk;27.0.12077973" >&2
        NDK="$SDK/ndk/27.0.12077973"
      fi
      BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
      rustup target add aarch64-linux-android >&2
      export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$BIN/aarch64-linux-android28-clang"
      export CC_aarch64_linux_android="$BIN/aarch64-linux-android28-clang"
      export AR_aarch64_linux_android="$BIN/llvm-ar"
      cargo build --locked --release --target aarch64-linux-android >&2
      OUT="$ROOT/android/app/src/main/jniLibs/arm64-v8a"
      mkdir -p "$OUT"
      cp "$CARGO_TARGET_DIR/aarch64-linux-android/release/libopenaide_encryption.so" "$OUT/"
      echo "$OUT/libopenaide_encryption.so"
      ;;
    host)
      cargo build --locked --release >&2
      echo "$CARGO_TARGET_DIR/release/libopenaide_encryption.so"
      ;;
    *)
      echo "Unknown target: $what (android or host)" >&2
      exit 2
      ;;
  esac
done

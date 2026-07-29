#!/bin/bash
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
XCFRAMEWORK_DIR="$ROOT_DIR/Vendor/TypesetLang.xcframework"

# The slices build-typeset-lang-xcframework.sh compiles.
RUST_TARGETS=(
  aarch64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)

# Everything cargo needs before it can resolve the FFI crate. Run only when a
# rebuild is actually due, so incremental builds stay free.
bootstrap() {
  # The crate reaches the pinned Typst fork through path dependencies, so a
  # fresh clone has nothing for cargo to resolve until this is checked out.
  if [ ! -f "$ROOT_DIR/Vendor/typst/Cargo.toml" ]; then
    echo "note: checking out the Vendor/typst submodule"
    git -C "$ROOT_DIR" submodule update --init --recursive Vendor/typst
  fi

  # Xcode's build phases run with a trimmed PATH, so look where rustup installs
  # itself before falling back to the environment's.
  local rustup_bin="${RUSTUP:-$HOME/.cargo/bin/rustup}"
  if [ ! -x "$rustup_bin" ]; then
    rustup_bin="$(command -v rustup || true)"
  fi
  if [ -n "$rustup_bin" ] && [ -x "$rustup_bin" ]; then
    "$rustup_bin" target add "${RUST_TARGETS[@]}" >/dev/null
  fi
}

has_all_binaries() {
  [ -f "$XCFRAMEWORK_DIR/macos-arm64/TypesetLang.framework/TypesetLang" ] &&
    [ -f "$XCFRAMEWORK_DIR/ios-arm64/TypesetLang.framework/TypesetLang" ] &&
    [ -f "$XCFRAMEWORK_DIR/ios-arm64_x86_64-simulator/TypesetLang.framework/TypesetLang" ]
}

needs_rebuild() {
  if ! has_all_binaries; then
    return 0
  fi

  local marker="$XCFRAMEWORK_DIR/macos-arm64/TypesetLang.framework/TypesetLang"
  local inputs=(
    "$ROOT_DIR/Scripts/build-typeset-lang-xcframework.sh"
    "$ROOT_DIR/Vendor/typeset-lang-ffi/Cargo.toml"
    "$ROOT_DIR/Vendor/typeset-lang-ffi/Cargo.lock"
    "$ROOT_DIR/Vendor/typeset-lang-ffi/include/typeset_lang.h"
    "$ROOT_DIR/Vendor/typeset-lang-ffi/src/lib.rs"
  )

  local input
  for input in "${inputs[@]}"; do
    if [ "$input" -nt "$marker" ]; then
      return 0
    fi
  done

  return 1
}

if needs_rebuild; then
  bootstrap
  "$ROOT_DIR/Scripts/build-typeset-lang-xcframework.sh"
fi

if ! has_all_binaries; then
  echo "error: TypesetLang.xcframework is incomplete after build." >&2
  exit 1
fi

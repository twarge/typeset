#!/bin/bash
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
XCFRAMEWORK_DIR="$ROOT_DIR/Vendor/TypesetLang.xcframework"

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
  "$ROOT_DIR/Scripts/build-typeset-lang-xcframework.sh"
fi

if ! has_all_binaries; then
  echo "error: TypesetLang.xcframework is incomplete after build." >&2
  exit 1
fi

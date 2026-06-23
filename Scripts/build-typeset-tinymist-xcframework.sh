#!/bin/bash
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/Vendor/typeset-tinymist-ffi"
BUILD_DIR="$ROOT_DIR/Vendor/Build/TypesetTinymist"
OUT_DIR="$ROOT_DIR/Vendor/TypesetTinymist.xcframework"
CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-15.0}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-26.0}"

if [ ! -x "$CARGO_BIN" ]; then
  CARGO_BIN="$(command -v cargo || true)"
fi
if [ -z "$CARGO_BIN" ] || [ ! -x "$CARGO_BIN" ]; then
  echo "error: cargo is required to build TypesetTinymist" >&2
  exit 1
fi

export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$ROOT_DIR=. --remap-path-prefix=${HOME:-$ROOT_DIR}=~"

build_target() {
  local rust_target="$1"
  local sdk="$2"
  local min_version="$3"
  local out_name="$4"
  local sdk_path
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

  export SDKROOT="$sdk_path"
  export MACOSX_DEPLOYMENT_TARGET="$min_version"
  export IPHONEOS_DEPLOYMENT_TARGET="$min_version"

  "$CARGO_BIN" build \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    --release \
    --target "$rust_target"

  local lib_path="$CRATE_DIR/target/$rust_target/release/libtypeset_tinymist_ffi.a"
  local framework_dir="$BUILD_DIR/$out_name/TypesetTinymist.framework"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$lib_path" "$framework_dir/TypesetTinymist"
  # Strip debug info from the Rust staticlib. Its DWARF references rustc temp
  # build dirs (target/.../deps/rustc*/) that are deleted after the build, so a
  # dSYM-generating link (DEBUG_INFORMATION_FORMAT=dwarf-with-dsym) warns
  # "unable to open object file" for them. -S removes only debug/local symbols and
  # keeps the global FFI symbols the app links against; the dropped debug info is
  # third-party Rust that is never symbolicated anyway.
  strip -S "$framework_dir/TypesetTinymist"
  cp "$CRATE_DIR/include/typeset_tinymist.h" "$framework_dir/Headers/TypesetTinymist.h"
  cat > "$framework_dir/Modules/module.modulemap" <<'MODULEMAP'
framework module TypesetTinymist {
  umbrella header "TypesetTinymist.h"
  export *
  module * { export * }
}
MODULEMAP
}

build_universal_simulator() {
  build_target "aarch64-apple-ios-sim" "iphonesimulator" "$IOS_MIN_VERSION" "ios-simulator-arm64"
  build_target "x86_64-apple-ios" "iphonesimulator" "$IOS_MIN_VERSION" "ios-simulator-x86_64"

  local framework_dir="$BUILD_DIR/ios-simulator-universal/TypesetTinymist.framework"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$CRATE_DIR/include/typeset_tinymist.h" "$framework_dir/Headers/TypesetTinymist.h"
  cp "$BUILD_DIR/ios-simulator-arm64/TypesetTinymist.framework/Modules/module.modulemap" "$framework_dir/Modules/module.modulemap"
  lipo -create \
    "$BUILD_DIR/ios-simulator-arm64/TypesetTinymist.framework/TypesetTinymist" \
    "$BUILD_DIR/ios-simulator-x86_64/TypesetTinymist.framework/TypesetTinymist" \
    -output "$framework_dir/TypesetTinymist"
}

rm -rf "$BUILD_DIR" "$OUT_DIR"
mkdir -p "$BUILD_DIR"

build_target "aarch64-apple-darwin" "macosx" "$MACOS_MIN_VERSION" "macos-arm64"
build_target "aarch64-apple-ios" "iphoneos" "$IOS_MIN_VERSION" "ios-arm64"
build_universal_simulator

xcodebuild -create-xcframework \
  -framework "$BUILD_DIR/macos-arm64/TypesetTinymist.framework" \
  -framework "$BUILD_DIR/ios-arm64/TypesetTinymist.framework" \
  -framework "$BUILD_DIR/ios-simulator-universal/TypesetTinymist.framework" \
  -output "$OUT_DIR"

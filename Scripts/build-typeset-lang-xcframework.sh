#!/bin/bash
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/Vendor/typeset-lang-ffi"
BUILD_DIR="$ROOT_DIR/Vendor/Build/TypesetLang"
OUT_DIR="$ROOT_DIR/Vendor/TypesetLang.xcframework"
CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-15.0}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-26.0}"

if [ ! -x "$CARGO_BIN" ]; then
  CARGO_BIN="$(command -v cargo || true)"
fi
if [ -z "$CARGO_BIN" ] || [ ! -x "$CARGO_BIN" ]; then
  echo "error: cargo is required to build TypesetLang" >&2
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
  # Deliberately NOT exporting MACOSX_/IPHONEOS_DEPLOYMENT_TARGET. Cargo runs
  # host proc-macros in the same environment as the target units, and on
  # macOS 27 beta 2 a proc-macro dylib linked with an explicit deployment
  # target produces metadata rustc can't read back ("can't find crate for
  # <x>_derive"; before Xcode 27A5228h it surfaced as dyld rejecting the
  # dylib outright). Verified empirically: any value fails, unset works.
  # The cost is only that the staticlib's objects are stamped with the
  # toolchain's default minimum instead of $min_version — harmless, since the
  # final app link warns only when an object's minimum is NEWER than the
  # app's.
  unset MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET

  # The min-version stamp still matters for C/asm objects built by the `cc`
  # crate (psm's assembly, notably): without direction they stamp at the host
  # OS, which can be newer than the app's target and draws an ld warning.
  # Scope the deployment target to the C compiler alone via cc's per-target
  # CFLAGS — those flags never reach rustc, so the dylib problem above can't
  # come back through this path.
  local version_min_flag
  case "$sdk" in
    macosx) version_min_flag="-mmacosx-version-min=$min_version" ;;
    iphoneos) version_min_flag="-miphoneos-version-min=$min_version" ;;
    iphonesimulator) version_min_flag="-mios-simulator-version-min=$min_version" ;;
  esac
  export "CFLAGS_${rust_target//-/_}=$version_min_flag"

  "$CARGO_BIN" build \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    --release \
    --target "$rust_target"

  local lib_path="$CRATE_DIR/target/$rust_target/release/libtypeset_lang_ffi.a"
  local framework_dir="$BUILD_DIR/$out_name/TypesetLang.framework"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$lib_path" "$framework_dir/TypesetLang"
  # Strip debug info from the Rust staticlib. Its DWARF references rustc temp
  # build dirs (target/.../deps/rustc*/) that are deleted after the build, so a
  # dSYM-generating link (DEBUG_INFORMATION_FORMAT=dwarf-with-dsym) warns
  # "unable to open object file" for them. -S removes only debug/local symbols and
  # keeps the global FFI symbols the app links against; the dropped debug info is
  # third-party Rust that is never symbolicated anyway.
  strip -S "$framework_dir/TypesetLang"
  cp "$CRATE_DIR/include/typeset_lang.h" "$framework_dir/Headers/TypesetLang.h"
  cat > "$framework_dir/Modules/module.modulemap" <<'MODULEMAP'
framework module TypesetLang {
  umbrella header "TypesetLang.h"
  export *
  module * { export * }
}
MODULEMAP
}

build_universal_simulator() {
  build_target "aarch64-apple-ios-sim" "iphonesimulator" "$IOS_MIN_VERSION" "ios-simulator-arm64"
  build_target "x86_64-apple-ios" "iphonesimulator" "$IOS_MIN_VERSION" "ios-simulator-x86_64"

  local framework_dir="$BUILD_DIR/ios-simulator-universal/TypesetLang.framework"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "$CRATE_DIR/include/typeset_lang.h" "$framework_dir/Headers/TypesetLang.h"
  cp "$BUILD_DIR/ios-simulator-arm64/TypesetLang.framework/Modules/module.modulemap" "$framework_dir/Modules/module.modulemap"
  lipo -create \
    "$BUILD_DIR/ios-simulator-arm64/TypesetLang.framework/TypesetLang" \
    "$BUILD_DIR/ios-simulator-x86_64/TypesetLang.framework/TypesetLang" \
    -output "$framework_dir/TypesetLang"
}

rm -rf "$BUILD_DIR" "$OUT_DIR"
mkdir -p "$BUILD_DIR"

build_target "aarch64-apple-darwin" "macosx" "$MACOS_MIN_VERSION" "macos-arm64"
build_target "aarch64-apple-ios" "iphoneos" "$IOS_MIN_VERSION" "ios-arm64"
build_universal_simulator

xcodebuild -create-xcframework \
  -framework "$BUILD_DIR/macos-arm64/TypesetLang.framework" \
  -framework "$BUILD_DIR/ios-arm64/TypesetLang.framework" \
  -framework "$BUILD_DIR/ios-simulator-universal/TypesetLang.framework" \
  -output "$OUT_DIR"

#!/usr/bin/env bash
# Copyright (c) 2026 Twarge LLC.
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Typeset"
CONFIGURATION="${CONFIGURATION:-release}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_DIR/Xcode}"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/$APP_NAME.app}"
PROJECT="$ROOT_DIR/Typeset.xcodeproj"
SCHEME="${SCHEME:-Typeset}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-257KW9ZJFP}"
ASSET_SYMBOL_EXTENSIONS="${ASSET_SYMBOL_EXTENSIONS:-YES}"
HARDENED_RUNTIME="${HARDENED_RUNTIME:-YES}"

case "$CONFIGURATION" in
	debug|Debug)
		XCODE_CONFIGURATION="Debug"
		;;
	release|Release)
		XCODE_CONFIGURATION="Release"
		;;
	*)
		echo "usage: CONFIGURATION=[debug|release] $0" >&2
		exit 64
		;;
esac

cd "$ROOT_DIR"
mkdir -p "$BUILD_DIR"

build_settings=(
	ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS="$ASSET_SYMBOL_EXTENSIONS"
	CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED"
	ENABLE_HARDENED_RUNTIME="$HARDENED_RUNTIME"
)

if [[ "$CODE_SIGNING_ALLOWED" != "NO" ]]; then
	build_settings+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

xcodebuild \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$XCODE_CONFIGURATION" \
	-destination "generic/platform=macOS" \
	-derivedDataPath "$DERIVED_DATA_PATH" \
	"${build_settings[@]}" \
	build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$XCODE_CONFIGURATION/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || {
	echo "error: built app not found: $BUILT_APP" >&2
	exit 1
}

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
ditto "$BUILT_APP" "$APP_DIR"

echo "$APP_DIR"

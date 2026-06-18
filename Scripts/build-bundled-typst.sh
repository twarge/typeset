#!/usr/bin/env bash
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
	exit 0
fi

CARGO_BIN="${CARGO:-$HOME/.cargo/bin/cargo}"
if [[ ! -x "$CARGO_BIN" ]]; then
	CARGO_BIN="$(command -v cargo || true)"
fi
if [[ -z "$CARGO_BIN" || ! -x "$CARGO_BIN" ]]; then
	echo "error: cargo is required to build bundled Typst" >&2
	exit 1
fi

TYPST_ROOT="$SRCROOT/Vendor/typst"
BUILT_TYPST="$TYPST_ROOT/target/release/typst"
BUNDLED_TYPST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/typst"
TEMP_DSYM="$TARGET_TEMP_DIR/typst.dSYM"

# Typst's upstream release profile strips the CLI package. Keep our bundled
# helper optimized, but preserve enough DWARF for App Store symbol upload.
export CARGO_PROFILE_RELEASE_DEBUG="${CARGO_PROFILE_RELEASE_DEBUG:-line-tables-only}"
export CARGO_PROFILE_RELEASE_STRIP="${CARGO_PROFILE_RELEASE_STRIP:-none}"
export CARGO_PROFILE_RELEASE_PACKAGE_TYPST_CLI_STRIP="${CARGO_PROFILE_RELEASE_PACKAGE_TYPST_CLI_STRIP:-none}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$SRCROOT=. --remap-path-prefix=${HOME:-$SRCROOT}=~"

cd "$TYPST_ROOT"
"$CARGO_BIN" rustc --release -p typst-cli --bin typst -- -C debuginfo=1 -C strip=none

mkdir -p "$(dirname "$BUNDLED_TYPST")"
cp "$BUILT_TYPST" "$BUNDLED_TYPST"
chmod 755 "$BUNDLED_TYPST"

rm -rf "$TEMP_DSYM"
if command -v dsymutil >/dev/null 2>&1; then
	dsymutil "$BUNDLED_TYPST" -o "$TEMP_DSYM"

	if [[ -d "$TEMP_DSYM" ]]; then
		if [[ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]]; then
			mkdir -p "$DWARF_DSYM_FOLDER_PATH"
			rm -rf "$DWARF_DSYM_FOLDER_PATH/typst.dSYM"
			cp -R "$TEMP_DSYM" "$DWARF_DSYM_FOLDER_PATH/typst.dSYM"
		fi

		if [[ -n "${ARCHIVE_DSYMS_FOLDER_PATH:-}" ]]; then
			mkdir -p "$ARCHIVE_DSYMS_FOLDER_PATH"
			rm -rf "$ARCHIVE_DSYMS_FOLDER_PATH/typst.dSYM"
			cp -R "$TEMP_DSYM" "$ARCHIVE_DSYMS_FOLDER_PATH/typst.dSYM"
		fi
	fi
else
	echo "warning: dsymutil not found; bundled typst dSYM will not be generated" >&2
fi

# Xcode does not strip helper executables copied into Resources. Generate the
# dSYM first, then remove debug sections from the bundled helper before signing.
STRIP_TOOL="${STRIP:-strip}"
if command -v "$STRIP_TOOL" >/dev/null 2>&1; then
	"$STRIP_TOOL" -Sx "$BUNDLED_TYPST" || echo "warning: failed to strip debug sections from bundled typst" >&2
else
	echo "warning: strip not found; bundled typst will retain debug sections" >&2
fi

# The sandboxed app spawns this helper; it needs the inherit entitlement to
# join the app's sandbox and keep its dynamic file-access grants.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
	IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
	codesign --force --sign "$IDENTITY" --entitlements "$SRCROOT/Config/TypstCLI.entitlements" --options runtime --timestamp=none "$BUNDLED_TYPST"
fi

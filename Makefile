# Builds are identical to pressing Build in Xcode: plain xcodebuild against
# the shared scheme, default derived data, automatic signing — no overrides.
# The Xcode project builds its own dependencies (the TypesetLang.xcframework
# from the Rust FFI crate, and the bundled Typst CLI), so a fresh clone
# builds from scratch with a bare `make`.

SCHEME := Typeset
CONFIGURATION := Debug

.PHONY: all icons macos ios clean

all: macos

# Regenerates the app and document icon artwork. The generated files are
# committed, so this is only needed after changing the icon design — builds
# never depend on it (nor does Xcode's).
icons:
	swift Scripts/generate-icons.swift

macos:
	xcodebuild build -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS'

ios:
	xcodebuild build -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'generic/platform=iOS Simulator'

clean:
	xcodebuild clean -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'platform=macOS'
	xcodebuild clean -scheme $(SCHEME) -configuration $(CONFIGURATION) -destination 'generic/platform=iOS Simulator'

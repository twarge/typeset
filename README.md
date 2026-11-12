# Typeset

[![CI](https://github.com/twarge/typeset/actions/workflows/ci.yml/badge.svg)](https://github.com/twarge/typeset/actions/workflows/ci.yml)

Typeset is a document-based SwiftUI app for macOS and iOS that opens `.typeset` package folders. A package is just a directory with a `.typeset` extension containing one or more Typst source files plus images and other compilation assets.

## License

Typeset's source code is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full license text.

## What Exists

- A Swift package with a shared `TypesetCore` module and a SwiftUI `Typeset` app target.
- `DocumentGroup` support for reading and writing `.typeset` folder packages.
- A left sidebar that lists every file in the package.
- A source editor that opens the selected file and writes text edits back into the document package.
- A WebKit preview view with source-position metadata embedded in the generated HTML.
- Click-to-seek from preview back to the source editor.
- PDF export through the embedded Typst compiler.
- The compiler as a system verb: a `Compile Typst` App Intent for Shortcuts
  (source text in, a PDF file out — on iOS too), and a macOS Service,
  `Compile Typst to PDF`, that other apps can call with Typst text on a
  pasteboard and get PDF data back. Calcium's Typeset PDF command uses the
  service when Typeset is installed.
- Typst checked in as a Git submodule at `Vendor/typst`.

## Typst Integration

Typst is compiled into the app. `Vendor/typeset-lang-ffi` is a small Rust crate that wraps the compiler and language tooling from the `Vendor/typst` submodule behind a C interface; the Xcode project builds it into `Vendor/TypesetLang.xcframework`, which `TypesetCore` links on both macOS and iOS. Preview, PDF export, the Shortcuts intent, and the macOS Service all compile through it, so the app runs no helper process and bundles no `typst` binary.

Typeset hands the compiler an app-owned local package directory and package cache directory. That lets `#import "@preview/package:version"` work like it does in the Typst CLI: locally installed packages are checked first, and missing Typst Universe packages are downloaded into Typeset's cache on first use. These directories live under `Application Support/Typeset/Typst/Packages` in the app's container.

The packages the sample document imports, and everything they import in turn, ship in `Resources/TypstPackages` exactly as published and are copied into the cache before the first compile, so a new document renders offline. `Scripts/fetch-bundled-packages.sh` refreshes them; run it after changing the sample document's imports. Each package keeps its own license (CeTZ is LGPL-3.0-or-later), listed with source links in `Resources/Acknowledgements/TypstPackages-NOTICE.txt`. Settings > Typst Packages lists every installed package with its license and sources, and can replace one with a user's modified copy by placing it in the local package directory, which the compiler reads first.

## System Integration

- **Extensions (macOS):** `TypesetQuickLook` previews documents, `TypesetThumbnail` draws the first page as the Finder icon, and `TypesetSpotlight` gives Spotlight the text inside a package.
- **Shortcuts:** `Intents.swift` and `DocumentIntents.swift` offer Compile Typst, Export Typst File as PDF and Create Typst File, plus a Focus filter that turns on distraction-free mode.
- **Printing and sharing:** File > Print and, on macOS, File > Share PDF compile to a temporary PDF first (`DocumentOutput.swift`).
- **Writing Tools:** limited to the prose ranges the language service reports, so markup is never rewritten (`SystemTextSupport.swift`).
- **Settings sync:** `SettingsSync.swift` mirrors a fixed list of preferences through iCloud's key-value store. This needs the `ubiquity-kvstore-identifier` entitlement, so a signed build needs the iCloud capability on its App ID.
- **iCloud Drive folder:** the app declares a public container (`iCloud.com.twarge.app.typeset`, shown as "Typeset" in iCloud Drive) in `NSUbiquitousContainers` and its entitlements. Nothing in the code depends on it; documents can still live anywhere. The folder appears only after a build with a higher `CFBundleVersion` has run.
- **Diagnostics:** MetricKit crash and hang reports are kept as JSON under `Application Support/Typeset/Diagnostics`.
- **Localisation:** user-facing strings are collected in `Resources/Localizable.xcstrings`. Xcode updates it on each build; English is the only language so far.

## Preview Architecture

Tinymist obtains its editor preview through a web preview surface and a data-plane bridge that maps rendered elements back to Typst source spans. Typeset follows that same high-level shape:

1. `TypstRenderer.preview(package:)` returns an `HTMLPreview`.
2. `PreviewHTMLBuilder` emits HTML blocks with `data-source` identifiers.
3. The embedded JavaScript posts the clicked source range to WebKit.
4. `PreviewWebView` converts that message into a `SourceRange`.
5. `TypesetWorkspaceView` selects the source file and scrolls/selects the matching range.

The current HTML renderer is intentionally simple starter infrastructure. The next deeper step is replacing `PreviewHTMLBuilder` with a Typst-backed HTML/SVG preview pipeline while preserving the same `HTMLPreview` and click-to-seek bridge.

## Development

Open `Typeset.xcodeproj` and press Run — that is the build system, in its
entirety. Xcode builds its own dependencies: the `TypesetCore` target's first
build phase produces `TypesetLang.xcframework` from the Rust FFI crate. It
checks out the pinned `Vendor/typst` submodule and installs the Apple Rust
targets on first use, so a fresh clone needs no terminal step beyond having
`cargo` installed (rustup's `~/.cargo/bin`, or anywhere on `PATH`).

`make` is the same build from the command line (plain `xcodebuild`, no
overrides):

```sh
make          # macOS app
```

```sh
make ios      # iOS Simulator
```

`make icons` regenerates the checked-in icon artwork; `make clean` cleans
both platforms. Releases are the App Store workflow
(`.github/workflows/appstore.yml`), which archives and uploads both apps
with the same xcodebuild invocations.

The project contains a unified multiplatform `Typeset` app target plus shared
`TypesetCore`, `TypesetQuickLook`, and `TypesetCoreTests` targets. The app
sources use platform wrappers for AppKit and UIKit so the same workspace UI is
hosted on both macOS and iOS.

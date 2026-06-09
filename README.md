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
- PDF export through the Typst command-line tool.
- Typst checked in as a Git submodule at `Vendor/typst`.

## Typst Integration

The macOS Xcode target builds the Typst CLI from the submodule and bundles it into the app at `Contents/Resources/typst`. PDF export uses that bundled binary first.

You can also build the Typst CLI manually for SwiftPM or command-line development:

```sh
cd Vendor/typst
cargo build --release --bin typst
```

If the app bundle does not contain `typst`, Typeset looks for `Vendor/typst/target/release/typst` from the current working directory.

You can also point the app at a specific Typst binary with `TYPESET_TYPST_PATH`.

Typeset passes an app-owned local package directory and package cache directory to `typst compile`. That lets `#import "@preview/package:version"` work like it does in the Typst CLI: locally installed packages are checked first, and missing Typst Universe packages can be downloaded into Typeset's cache during export. On macOS these directories live under `~/Library/Application Support/Typeset/Typst/Packages`.

## Preview Architecture

Tinymist obtains its editor preview through a web preview surface and a data-plane bridge that maps rendered elements back to Typst source spans. Typeset follows that same high-level shape:

1. `TypstRenderer.preview(package:)` returns an `HTMLPreview`.
2. `PreviewHTMLBuilder` emits HTML blocks with `data-source` identifiers.
3. The embedded JavaScript posts the clicked source range to WebKit.
4. `PreviewWebView` converts that message into a `SourceRange`.
5. `TypesetWorkspaceView` selects the source file and scrolls/selects the matching range.

The current HTML renderer is intentionally simple starter infrastructure. The next deeper step is replacing `PreviewHTMLBuilder` with a Typst-backed HTML/SVG preview pipeline while preserving the same `HTMLPreview` and click-to-seek bridge.

## Development

```sh
swift build
swift test
```

Open the package in Xcode to run the SwiftUI app on macOS. The app sources use platform wrappers for AppKit and UIKit so the same workspace UI can be hosted by an iOS app target as the project grows.

You can also open `Typeset.xcodeproj`, which contains a unified multiplatform `Typeset` app target, plus shared `TypesetCore`, `TypesetQuickLook`, and `TypesetCoreTests` targets.

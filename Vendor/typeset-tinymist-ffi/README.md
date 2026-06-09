# Typeset Tinymist FFI

This crate is Typeset's C ABI boundary for embedded Typst language intelligence.
It is intentionally small: Swift owns editor UI and document state, while this
crate owns Typst-aware parsing/query behavior and returns JSON payloads.

`Vendor/tinymist` is vendored separately as the upstream source of the language
engine. The first adapter implementation uses the same Typst parser generation as
Tinymist and keeps the ABI stable while deeper Tinymist query integration is
expanded behind it.

Build all Apple slices with:

```sh
Scripts/build-typeset-tinymist-xcframework.sh
```


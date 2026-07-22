# Typeset Tinymist FFI

This crate is Typeset's C ABI boundary for embedded Typst language intelligence.
It is intentionally small: Swift owns editor UI and document state, while this
crate owns Typst-aware parsing/query behavior and returns JSON payloads.

Despite the historical "tinymist" naming, tinymist itself is not embedded: the
language engine is `typst-ide` (completions, definitions, tooltips) plus this
crate's own analysis, all built directly against the `Vendor/typst` crates. The
name is kept for ABI stability; adopting tinymist's query crates remains a
possible future direction.

Build all Apple slices with:

```sh
Scripts/build-typeset-lang-xcframework.sh
```


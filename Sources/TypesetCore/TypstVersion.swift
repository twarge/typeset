// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(TypesetLang)
import TypesetLang
#endif

/// Information about the embedded Typst toolchain.
public enum TypstRuntime {
    /// Version of the Typst compiler that ships with this build.
    ///
    /// When the embedded Typst framework is linked (the Xcode app target), this
    /// is read straight from the compiler so it can never drift from what is
    /// actually bundled. In SwiftPM-only builds (tests, CI) the framework is not
    /// linked, so we fall back to the version of the pinned `Vendor/typst`
    /// submodule.
    public static let typstVersion: String = {
        #if canImport(TypesetLang)
        if let pointer = typeset_typst_version() {
            defer { typeset_lang_string_free(pointer) }
            let value = String(cString: pointer)
            if !value.isEmpty { return value }
        }
        #endif
        return bundledTypstVersion
    }()

    /// Builds the compiler's font store ahead of the first compile.
    ///
    /// Finding the system's fonts is the slowest thing the embedded compiler
    /// does that has nothing to do with the document, and it happens on
    /// whichever request needs fonts first — until now the first preview,
    /// which the user is watching. Call this at launch to spend that time
    /// while a document is still opening. It returns immediately, the work
    /// runs on the rendering queue (so a compile that arrives early simply
    /// waits for it rather than racing it), and the store is built once per
    /// process, so later calls cost nothing.
    public static func warmUp() {
        #if canImport(TypesetLang)
        EmbeddedRustWorkQueue.rendering.enqueue {
            // The bundled packages go into the cache here too, off the main
            // thread and ahead of the first compile that would import them.
            if let storage = try? TypstPackageStorage.appSupportStorage() {
                try? storage.createDirectories()
            }
            // First, as on every path into the compiler: the store is built
            // once, from whatever fonts it has been told about by then.
            TypstBundledFonts.installOnce()
            if let pointer = typeset_typst_warm_fonts() {
                typeset_lang_string_free(pointer)
            }
        }
        #endif
    }

    /// Version of the `Vendor/typst` submodule this source tree is pinned to.
    /// Keep in sync when bumping the submodule.
    static let bundledTypstVersion = "0.15.1"
}

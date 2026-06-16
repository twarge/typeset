// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(TypesetTinymist)
import TypesetTinymist
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
        #if canImport(TypesetTinymist)
        if let pointer = typeset_typst_version() {
            defer { typeset_tinymist_string_free(pointer) }
            let value = String(cString: pointer)
            if !value.isEmpty { return value }
        }
        #endif
        return bundledTypstVersion
    }()

    /// Version of the `Vendor/typst` submodule this source tree is pinned to.
    /// Keep in sync when bumping the submodule.
    static let bundledTypstVersion = "0.15.0"
}

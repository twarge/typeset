// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(TypesetLang)
import TypesetLang
#endif

/// The fonts Typeset ships for scripts the system leaves undrawable.
///
/// Apple's platforms have no font the Typst compiler can use for simplified
/// Chinese: PingFang's outlines are in a format only Core Text can draw, and the
/// Hiragino fonts cover only the characters Japanese shares with Chinese. So
/// text like 汉语 came out as tofu on iOS. Noto Sans CJK fills that gap, and the
/// bundle carries it because a document has to render the same whether or not
/// the reader happens to have installed a Chinese font.
///
/// The files live in `TypesetCore.framework` rather than the app, so the Quick
/// Look extension — which compiles through the same embedded Typst — finds them
/// at the same path.
public enum TypstBundledFonts {
    /// The bundled font directory, or `nil` in builds that don't carry it (the
    /// SwiftPM test bundle).
    public static let directoryURL: URL? = {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.resourceURL?.appending(path: directoryName, directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }()

    /// Hands the directory to the embedded compiler. Called before the first
    /// compile; later calls are ignored there, so calling it often is harmless.
    static func install() {
        #if canImport(TypesetLang)
        guard let path = directoryURL?.path else { return }
        if let pointer = typeset_typst_set_bundled_font_directory(path) {
            typeset_lang_string_free(pointer)
        }
        #endif
    }

    private static let directoryName = "NotoCJK"
}

/// Locates the framework holding this source, whichever bundle that turns out
/// to be (the app's embedded copy, or the Quick Look extension's).
private final class BundleToken {}

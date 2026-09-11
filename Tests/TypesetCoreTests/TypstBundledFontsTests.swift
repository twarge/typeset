// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

@Test func bundledFontsShipWithTheFramework() throws {
    let directory = try #require(
        TypstBundledFonts.directoryURL,
        "the bundled fonts are missing from TypesetCore.framework"
    )
    let names = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .sorted()
    #expect(names == ["LICENSE", "NotoSansCJK-Bold.ttc", "NotoSansCJK-Regular.ttc"])
}

/// The compiler has to be told where the bundled fonts are before its font book
/// is built. Asking for one by name proves that happened: Typst warns about an
/// unknown font family when its book doesn't hold the font. (Whether fallback
/// then picks it for unstyled Chinese is the Rust suite's business.)
@Test func bundledFontsReachTheCompiler() async throws {
    let source = "#set text(font: \"Noto Sans CJK SC\")\n汉语说让"
    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data(source.utf8))
    ])

    let preview = try await TypstRenderer().previewPDF(package: package)

    #expect(!preview.data.isEmpty)
    #expect(
        !preview.diagnosticsMessage.contains("unknown font family"),
        "\(preview.diagnosticsMessage)"
    )
}

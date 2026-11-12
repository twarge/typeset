// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CoreSpotlight
import Foundation
import TypesetCore

/// Tells Spotlight what a Typst document says, so it can be found by its
/// text and not only by its file name.
///
/// A Typeset package is a folder, which Spotlight cannot read on its own; this
/// hands it the text of every source file inside.
nonisolated final class ImportExtension: CSImportExtension {
    /// Enough to find a document by anything on its first few hundred pages
    /// without handing the index a book.
    private static let textLimit = 1 << 20

    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        let isPackage = (try? contentURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let sources: [String]
        if isPackage {
            let package = try DocumentPackage(fileWrapper: FileWrapper(url: contentURL, options: [.immediate]))
            let mainPath = package.mainTypstPath
            sources = package.files
                .filter { $0.isTextEditable }
                // The main file first: its opening lines describe the document.
                .sorted { ($0.path == mainPath ? 0 : 1, $0.path) < ($1.path == mainPath ? 0 : 1, $1.path) }
                .map { String(decoding: $0.data, as: UTF8.self) }
        } else {
            sources = [String(decoding: try Data(contentsOf: contentURL), as: UTF8.self)]
        }

        let text = String(sources.joined(separator: "\n\n").prefix(Self.textLimit))
        attributes.textContent = text
        attributes.displayName = contentURL.deletingPathExtension().lastPathComponent
        attributes.kind = isPackage ? "Typeset Package" : "Typst Source"
        attributes.contentDescription = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Skip set rules, imports and comments to reach something a
            // person wrote for a reader.
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }
}

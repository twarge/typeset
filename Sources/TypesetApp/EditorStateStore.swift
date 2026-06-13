// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import TypesetCore

/// Per-device editor state (cursor, scroll, viewport, sidebar layout) keyed
/// by document identity, stored in Application Support. Keeping this outside
/// the package means devices sharing a document — via iCloud Drive or a
/// collaboration replica — stop fighting over a single `.typesetstate` file.
/// The in-package state file remains a read fallback for older documents.
enum EditorStateStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typeset/EditorState", directoryHint: .isDirectory)
    }

    /// Stable identity for a document URL across launches and renames of
    /// unrelated path components — a digest of the standardized path.
    static func documentKey(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileURL(forKey key: String) -> URL {
        directory.appending(path: "\(key).toml")
    }

    static func save(_ package: DocumentPackage, forKey key: String) {
        let text = package.encodedEditorState()
        let url = fileURL(forKey: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            // Per-device state is best-effort; the in-package state still
            // round-trips through the document itself.
        }
    }

    static func load(forKey key: String) -> DocumentPackageState? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return DocumentPackage.decodeEditorState(text)
    }
}

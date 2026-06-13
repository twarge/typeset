// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A persisted merge base for one file of one shared document: the full
/// last-converged text (diff3 needs the text, not a hash) plus the server
/// change tag it corresponds to. Must survive launches and offline gaps.
public struct CollabBaseEntry: Codable, Equatable, Sendable {
    public var text: String
    public var changeTag: String?

    public init(text: String, changeTag: String? = nil) {
        self.text = text
        self.changeTag = changeTag
    }
}

public protocol CollabBaseStoring: Sendable {
    func loadBases(documentID: String) -> [String: CollabBaseEntry]
    func saveBase(_ entry: CollabBaseEntry, documentID: String, fileID: String)
    func removeBase(documentID: String, fileID: String)
    func removeDocument(documentID: String)
}

/// File-backed base store: one JSON file per (document, file) under an
/// injected root directory (Application Support in the app, a temp dir in
/// tests).
public struct FileCollabBaseStore: CollabBaseStoring {
    private let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    private func documentDirectory(_ documentID: String) -> URL {
        rootDirectory.appending(path: documentID, directoryHint: .isDirectory)
    }

    private func entryURL(documentID: String, fileID: String) -> URL {
        documentDirectory(documentID).appending(path: "\(fileID).json")
    }

    public func loadBases(documentID: String) -> [String: CollabBaseEntry] {
        let directory = documentDirectory(documentID)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [:] }
        var bases: [String: CollabBaseEntry] = [:]
        for url in contents where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(CollabBaseEntry.self, from: data) else { continue }
            bases[url.deletingPathExtension().lastPathComponent] = entry
        }
        return bases
    }

    public func saveBase(_ entry: CollabBaseEntry, documentID: String, fileID: String) {
        let url = entryURL(documentID: documentID, fileID: fileID)
        do {
            try FileManager.default.createDirectory(
                at: documentDirectory(documentID),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entry)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort: a missing base degrades to a whole-file conflict
            // on the next divergence rather than data loss.
        }
    }

    public func removeBase(documentID: String, fileID: String) {
        try? FileManager.default.removeItem(at: entryURL(documentID: documentID, fileID: fileID))
    }

    public func removeDocument(documentID: String) {
        try? FileManager.default.removeItem(at: documentDirectory(documentID))
    }
}

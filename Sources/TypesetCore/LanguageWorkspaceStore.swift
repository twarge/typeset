// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// On-disk mirrors of open documents for the language service to read.
///
/// A mirror is a full copy of a document, so it must not outlive the session
/// that made it. `remove(documentID:)` takes one down when its document
/// closes; and because a crash or a force-quit skips that, the first store to
/// create a workspace in a process first clears out whatever earlier launches
/// left behind.
public actor LanguageWorkspaceStore {
    private var workspaces: [String: URL] = [:]
    private let fileManager: FileManager
    private let baseDirectory: URL?

    /// - Parameter baseDirectory: Where the mirrors live. `nil` (the default)
    ///   is `Typeset/LanguageWorkspaces` in Application Support; tests pass a
    ///   directory of their own.
    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
    }

    public func materialize(package: DocumentPackage, documentID: String) throws -> URL {
        let root = try workspaceURL(for: documentID)
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        for folder in package.allFolderPaths {
            try fileManager.createDirectory(at: root.appending(path: folder, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }

        for file in package.files {
            let url = root.appending(path: file.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url, options: .atomic)
        }

        return root
    }

    public func updateFile(documentID: String, path: String, data: Data) throws -> URL {
        let root = try workspaceURL(for: documentID)
        let url = root.appending(path: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes a document's mirror. Call when the document closes; a mirror
    /// that was never materialized is simply not there to delete.
    public func remove(documentID: String) {
        guard let root = try? workspaceURL(for: documentID) else { return }
        try? fileManager.removeItem(at: root)
        workspaces[documentID] = nil
    }

    private func workspaceURL(for documentID: String) throws -> URL {
        if let existing = workspaces[documentID] {
            return existing
        }

        let base = try workspacesDirectory()
        Self.purgeLeftoversOnce(in: base, fileManager: fileManager)

        let root = base.appending(path: documentID, directoryHint: .isDirectory)
        workspaces[documentID] = root
        return root
    }

    private func workspacesDirectory() throws -> URL {
        if let baseDirectory {
            return baseDirectory
        }
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TypstRenderError.packageStorageUnavailable
        }

        let base = appSupport.appending(path: "Typeset", directoryHint: .isDirectory)
        // One-time cleanup: this mirror lived under "TinymistWorkspaces" before
        // the rename; stale copies of user documents shouldn't linger there.
        try? fileManager.removeItem(at: base.appending(path: "TinymistWorkspaces", directoryHint: .isDirectory))

        return base.appending(path: "LanguageWorkspaces", directoryHint: .isDirectory)
    }

    /// The directories already purged by this process. Every document window
    /// has a store of its own, so "once" has to be per process rather than
    /// per store: a second store purging would delete the first one's live
    /// mirror.
    private static let purgedDirectories = PurgedDirectories()

    private final class PurgedDirectories: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        /// Runs `purge` the first time `path` is seen in this process, and
        /// holds every other caller until it has finished: a second store
        /// that returned early could build its mirror while the first was
        /// still deleting what it took for leftovers.
        func purgeOnce(_ path: String, _ purge: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard paths.insert(path).inserted else { return }
            purge()
        }
    }

    private static func purgeLeftoversOnce(in directory: URL, fileManager: FileManager) {
        purgedDirectories.purgeOnce(directory.standardizedFileURL.path) {
            purgeLeftovers(in: directory, fileManager: fileManager)
        }
    }

    /// Removes every mirror in `directory`. Only sound before this process
    /// has created one there, which `purgeLeftoversOnce` guarantees.
    static func purgeLeftovers(in directory: URL, fileManager: FileManager = .default) {
        let leftovers = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for leftover in leftovers {
            try? fileManager.removeItem(at: leftover)
        }
    }
}


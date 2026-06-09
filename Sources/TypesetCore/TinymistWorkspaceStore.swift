// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

public actor TinymistWorkspaceStore {
    private var workspaces: [String: URL] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
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

    private func workspaceURL(for documentID: String) throws -> URL {
        if let existing = workspaces[documentID] {
            return existing
        }

        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TypstRenderError.packageStorageUnavailable
        }

        let root = appSupport
            .appending(path: "Typeset", directoryHint: .isDirectory)
            .appending(path: "TinymistWorkspaces", directoryHint: .isDirectory)
            .appending(path: documentID, directoryHint: .isDirectory)
        workspaces[documentID] = root
        return root
    }
}


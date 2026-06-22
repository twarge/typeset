// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import PhotosUI
import PDFKit
import SwiftUI
import TypesetCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import QuickLookUI
#else
import UIKit
import QuickLook
#endif

enum FileTreeSelection: Hashable {
    case file(String)
    case folder(String)

    init?(id: String?) {
        guard let id else { return nil }
        if let path = id.removingPrefix("file:") {
            self = .file(path)
        } else if let path = id.removingPrefix("folder:") {
            self = .folder(path)
        } else {
            return nil
        }
    }

    var id: String {
        switch self {
        case .file(let path):
            "file:\(path)"
        case .folder(let path):
            "folder:\(path)"
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

struct FileTreeNode: Identifiable {
    enum Kind {
        case folder
        case file(PackageFile)
    }

    var name: String
    var path: String
    var kind: Kind
    var children: [FileTreeNode] = []

    var id: String {
        switch kind {
        case .folder:
            return "folder:\(path)"
        case .file:
            return "file:\(path)"
        }
    }

    static func roots(files: [PackageFile], folders: [String], compileTargetPath: String) -> [FileTreeNode] {
        var root = BuilderNode(name: "", path: "")

        for folder in folders where !isHiddenPackagePath(folder) {
            root.insertFolder(parts: folder.split(separator: "/").map(String.init), prefix: "")
        }

        for file in files where !isHiddenPackagePath(file.path) {
            root.insert(file: file, parts: file.path.split(separator: "/").map(String.init), prefix: "")
        }

        return root.children
            .map(\.value)
            .sorted { BuilderNode.sort(lhs: $0, rhs: $1, compileTargetPath: compileTargetPath) }
            .map { $0.treeNode(compileTargetPath: compileTargetPath) }
    }
}

func isHiddenPackagePath(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0.hasPrefix(".") }
}

private struct BuilderNode {
    var name: String
    var path: String
    var file: PackageFile?
    var children: [String: BuilderNode] = [:]

    mutating func insertFolder(parts: [String], prefix: String) {
        guard let head = parts.first else { return }
        let path = prefix.isEmpty ? head : "\(prefix)/\(head)"
        var child = children[head] ?? BuilderNode(name: head, path: path)
        child.insertFolder(parts: Array(parts.dropFirst()), prefix: path)
        children[head] = child
    }

    mutating func insert(file: PackageFile, parts: [String], prefix: String) {
        guard let head = parts.first else { return }
        let path = prefix.isEmpty ? head : "\(prefix)/\(head)"
        var child = children[head] ?? BuilderNode(name: head, path: path)
        if parts.count == 1 {
            child.file = file
        } else {
            child.insert(file: file, parts: Array(parts.dropFirst()), prefix: path)
        }
        children[head] = child
    }

    func treeNode(compileTargetPath: String) -> FileTreeNode {
        if let file {
            return FileTreeNode(name: name, path: path, kind: .file(file))
        }

        return FileTreeNode(
            name: name,
            path: path,
            kind: .folder,
            children: children.values
                .sorted { Self.sort(lhs: $0, rhs: $1, compileTargetPath: compileTargetPath) }
                .map { $0.treeNode(compileTargetPath: compileTargetPath) }
        )
    }

    static func sort(lhs: BuilderNode, rhs: BuilderNode, compileTargetPath: String) -> Bool {
        let lhsRank = lhs.sortRank(compileTargetPath: compileTargetPath)
        let rhsRank = rhs.sortRank(compileTargetPath: compileTargetPath)
        if lhsRank == rhsRank {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhsRank < rhsRank
    }

    private func sortRank(compileTargetPath: String) -> Int {
        if file?.path == compileTargetPath {
            return 0
        }
        if file?.isTypstSource == true {
            return 1
        }
        if file == nil {
            return 2
        }
        return 3
    }
}


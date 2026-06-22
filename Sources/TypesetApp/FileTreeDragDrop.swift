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

struct PackageFileDragItem: Codable, Hashable, Transferable {
    var path: String
    var name: String
    var data: Data

    init(file: PackageFile) {
        path = file.path
        name = file.name
        data = file.data
    }

    static var transferRepresentation: some TransferRepresentation {
        // CodableRepresentation first so `.dropDestination` can decode it on
        // the receive side — listing the (export-only) FileRepresentation
        // first makes SwiftUI's decoder pick that and fail, breaking
        // internal sidebar moves. macOS drag-to-Finder still gets the file
        // first because the macOS drag uses `FileTreeDragPayload.itemProvider`,
        // whose registration order is independent of this list.
        CodableRepresentation(contentType: .typesetPackageFileDrag)
        ProxyRepresentation(exporting: \.path)
        FileRepresentation(exportedContentType: .data) { item in
            SentTransferredFile(try item.exportedFileURL())
        }
    }

    func exportedFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TypesetDragExports", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }
}

struct PackageFolderDragItem: Codable, Hashable, Transferable {
    var path: String
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .typesetPackageFolderDrag)
        ProxyRepresentation(exporting: \.path)
    }
}

/// Hand-built `NSItemProvider` for a folder row, used by macOS's `.onDrag`
/// for the same reason as `FileTreeDragPayload` — `.draggable` doesn't
/// bubble from child views on macOS, so only the empty Spacer area
/// would be draggable otherwise.
enum FolderTreeDragPayload {
    static func itemProvider(path: String, name: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let item = PackageFolderDragItem(path: path, name: name)
        provider.suggestedName = name
        MainActor.assumeIsolated {
            ActivePackageDrag.start(.folder(path))
        }

        provider.registerDataRepresentation(forTypeIdentifier: UTType.typesetPackageFolderDrag.identifier, visibility: .all) { completion in
            completion(try? JSONEncoder().encode(item), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(path.utf8), nil)
            return nil
        }
        return provider
    }
}

/// Hand-built `NSItemProvider` for a file row, used by macOS's `.onDrag`.
/// `.draggable(PackageFileDragItem)` is preferred on iOS (it coexists with
/// `.contextMenu`), but on macOS `.onDrag` is required because `.draggable`
/// doesn't bubble its long-press from child views (the icon and text),
/// leaving only the empty Spacer area draggable.
enum FileTreeDragPayload {
    static func itemProvider(for file: PackageFile) -> NSItemProvider {
        let provider = NSItemProvider()
        let item = PackageFileDragItem(file: file)
        MainActor.assumeIsolated {
            ActivePackageDrag.start(.file(file.path))
        }
        // Suggested filename includes the extension. We deliberately register
        // the bytes under the generic `public.data` UTI rather than the
        // file's specific image UTI: with an image UTI advertised on the
        // pasteboard, AppKit bridges through `NSFilePromiseProvider`, which
        // crashes Finder for image types on macOS 26. With only `public.data`
        // exposed, no promise wrapper is created — Finder just takes the
        // bytes and writes them to disk under `suggestedName` (which already
        // carries the right extension).
        provider.suggestedName = file.name

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            visibility: .all
        ) { completion in
            completion(file.data, nil)
            return nil
        }

        // Sidebar/editor payloads. Visibility stays `.all` because
        // `.ownProcess` blocks SwiftUI's in-process drop decoding too —
        // file-rep-first + a stem `suggestedName` is what keeps Finder
        // from writing the JSON.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.typesetPackageFileDrag.identifier, visibility: .all) { completion in
            completion(try? JSONEncoder().encode(item), nil)
            return nil
        }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data(file.path.utf8), nil)
            return nil
        }
        return provider
    }
}

struct PackageDropDelegate: DropDelegate {
    static let packageDragTypes = [
        UTType.typesetPackageFileDrag.identifier,
        UTType.typesetPackageFolderDrag.identifier,
    ]

    static let supportedTypes = packageDragTypes + [
        UTType.plainText.identifier,
        UTType.fileURL.identifier,
        UTType.image.identifier,
    ]

    var destinationFolder: String?
    var packageFilePaths: Set<String>
    var packageFolderPaths: Set<String>
    var onMoveFile: (String, String?) -> Void
    var onMoveFolder: (String, String?) -> Void
    var onImportFiles: ([URL], String?, Bool) -> Void
    var onError: (String, String) -> Void
    var onTargetedChanged: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let isValid = info.hasItemsConforming(to: Self.supportedTypes)
        typesetDropDebug("validate destination=\(destinationDescription) valid=\(isValid) registered=\(registeredTypeIdentifiers(in: info).joined(separator: ","))")
        return isValid
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if Self.isPackageDrop(info: info) {
            return MainActor.assumeIsolated {
                DropProposal(operation: .move)
            }
        }
        return MainActor.assumeIsolated {
            DropProposal(operation: .copy)
        }
    }

    /// A drop is an internal package move when it carries the app's own drag
    /// types. The `ActivePackageDrag` marker recovers internal drags whose
    /// custom types were stripped in transit, but it can outlive a row drag
    /// that ended outside the app — so it never overrides a drop whose
    /// providers carry external content such as Finder files or images.
    static func isPackageDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: Self.packageDragTypes) {
            return true
        }
        let providers = info.itemProviders(for: Self.supportedTypes)
        return MainActor.assumeIsolated {
            ActivePackageDrag.isFresh && !PackageDropLoader.hasExternalContent(in: providers)
        }
    }

    func dropEntered(info: DropInfo) {
        let isValid = validateDrop(info: info)
        onTargetedChanged(isValid)
    }

    func dropExited(info: DropInfo) {
        onTargetedChanged(false)
    }

    func dropEnded(info: DropInfo) {
        MainActor.assumeIsolated {
            ActivePackageDrag.clear()
        }
        onTargetedChanged(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let isPackageDrop = Self.isPackageDrop(info: info)
        let providers = info.itemProviders(for: Self.supportedTypes)
        typesetDropDebug("perform destination=\(destinationDescription) providers=\(providers.count) packageDrop=\(isPackageDrop)")

        Task { @MainActor in
            do {
                var payload = try await PackageDropLoader.load(
                    from: providers,
                    packageFilePaths: packageFilePaths,
                    packageFolderPaths: packageFolderPaths,
                    allowsExternalFiles: !isPackageDrop
                )
                if isPackageDrop,
                   payload.isEmpty,
                   let activePayload = ActivePackageDrag.consume(
                    packageFilePaths: packageFilePaths,
                    packageFolderPaths: packageFolderPaths
                   ) {
                    payload = activePayload
                }
                ActivePackageDrag.clear()
                typesetDropDebug("decoded destination=\(destinationDescription) files=\(payload.packageFilePaths) folders=\(payload.packageFolderPaths) external=\(payload.externalFileURLs.map(\.lastPathComponent))")
                for path in payload.packageFilePaths {
                    onMoveFile(path, destinationFolder)
                }
                for path in payload.packageFolderPaths {
                    onMoveFolder(path, destinationFolder)
                }
                if !payload.externalFileURLs.isEmpty {
                    onImportFiles(payload.externalFileURLs, destinationFolder, true)
                }
            } catch {
                ActivePackageDrag.clear()
                typesetDropDebug("failed destination=\(destinationDescription) error=\(error.localizedDescription)")
                onError("Drop failed", error.localizedDescription)
            }
        }

        onTargetedChanged(false)
        return true
    }

    private var destinationDescription: String {
        destinationFolder ?? "package root"
    }

    private func registeredTypeIdentifiers(in info: DropInfo) -> [String] {
        info.itemProviders(for: Self.supportedTypes)
            .flatMap(\.registeredTypeIdentifiers)
            .uniqued()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

@MainActor
enum PackageDropLoader {
    struct Payload {
        var packageFilePaths: [String] = []
        var packageFolderPaths: [String] = []
        var externalFileURLs: [URL] = []

        var isEmpty: Bool {
            packageFilePaths.isEmpty && packageFolderPaths.isEmpty && externalFileURLs.isEmpty
        }
    }

    /// True when any provider carries droppable external content — a file
    /// URL or image data — as opposed to the app's internal drag types.
    static func hasExternalContent(in providers: [NSItemProvider]) -> Bool {
        providers.contains { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || imageTypeIdentifier(for: provider) != nil
        }
    }

    static func load(
        from providers: [NSItemProvider],
        packageFilePaths: Set<String>,
        packageFolderPaths: Set<String>,
        allowsExternalFiles: Bool
    ) async throws -> Payload {
        var payload = Payload()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.typesetPackageFileDrag.identifier),
               let path = try await loadPackagePath(from: provider),
               packageFilePaths.contains(path) {
                payload.packageFilePaths.append(path)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.typesetPackageFolderDrag.identifier),
               let path = try await loadPackageFolderPath(from: provider),
               packageFolderPaths.contains(path) {
                payload.packageFolderPaths.append(path)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let path = try await loadString(from: provider, typeIdentifier: UTType.plainText.identifier),
               packageFilePaths.contains(path) {
                payload.packageFilePaths.append(path)
                continue
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let path = try await loadString(from: provider, typeIdentifier: UTType.plainText.identifier),
               packageFolderPaths.contains(path) {
                payload.packageFolderPaths.append(path)
                continue
            }

            if allowsExternalFiles,
               provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try await loadFileURL(from: provider),
               FileManager.default.isReadableFile(atPath: url.path) {
                payload.externalFileURLs.append(url)
                continue
            }

            // The sandbox can leave the pasteboard URL unreadable (or omit
            // the file-url representation entirely); ask the provider to
            // materialize a copy instead — the system performs that read
            // with the drag's own access grant.
            if allowsExternalFiles,
               let url = try await loadFileCopy(from: provider) {
                payload.externalFileURLs.append(url)
                continue
            }

            // Raw image data (e.g. dragged from Photos): materialize it to a
            // temporary file so it can be imported like any other file.
            if allowsExternalFiles,
               let imageTypeIdentifier = imageTypeIdentifier(for: provider),
               let data = try await loadData(from: provider, typeIdentifier: imageTypeIdentifier),
               let url = writeImageToTempFile(data: data, typeIdentifier: imageTypeIdentifier) {
                payload.externalFileURLs.append(url)
            }
        }

        return payload
    }

    /// First registered type identifier that is an image format Typst can
    /// render. TIFF is skipped — Typst doesn't render it.
    private static func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier),
                  type.conforms(to: .image),
                  type != .tiff else { continue }
            return identifier
        }
        return nil
    }

    private static func writeImageToTempFile(data: Data, typeIdentifier: String) -> URL? {
        let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypesetDroppedImages", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("Dropped Image.\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func loadPackagePath(from provider: NSItemProvider) async throws -> String? {
        let data = try await loadData(from: provider, typeIdentifier: UTType.typesetPackageFileDrag.identifier)
        return data.flatMap { try? JSONDecoder().decode(PackageFileDragItem.self, from: $0) }?.path
    }

    private static func loadPackageFolderPath(from provider: NSItemProvider) async throws -> String? {
        let data = try await loadData(from: provider, typeIdentifier: UTType.typesetPackageFolderDrag.identifier)
        return data.flatMap { try? JSONDecoder().decode(PackageFolderDragItem.self, from: $0) }?.path
    }

    private static func loadString(from provider: NSItemProvider, typeIdentifier: String) async throws -> String? {
        let data = try await loadData(from: provider, typeIdentifier: typeIdentifier)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Materializes a dropped item as a readable file inside the app
    /// container, preferring representations the system can deliver with
    /// the drag's sandbox grant.
    private static func loadFileCopy(from provider: NSItemProvider) async throws -> URL? {
        let skipped: Set<String> = [
            UTType.typesetPackageFileDrag.identifier,
            UTType.typesetPackageFolderDrag.identifier,
            UTType.fileURL.identifier,
            UTType.plainText.identifier,
        ]
        for identifier in provider.registeredTypeIdentifiers where !skipped.contains(identifier) {
            guard provider.hasRepresentationConforming(toTypeIdentifier: identifier, fileOptions: []) else {
                continue
            }
            if let url = await fileRepresentationCopy(from: provider, typeIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    private static func fileRepresentationCopy(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _, _ in
                // The URL is only valid (and, for in-place files, only
                // readable) inside this handler; copy it into our own
                // temporary directory before returning.
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TypesetDroppedFiles", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadFileURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: URL(string: string))
                } else if let string = item as? String {
                    continuation.resume(returning: URL(string: string))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
private enum ActivePackageDrag {
    enum Payload {
        case file(String)
        case folder(String)
    }

    private static var payload: Payload?
    private static var startedAt = Date.distantPast
    private static let maxAge: TimeInterval = 10

    static func start(_ nextPayload: Payload) {
        payload = nextPayload
        startedAt = Date()
    }

    static var isFresh: Bool {
        payload != nil && Date().timeIntervalSince(startedAt) <= maxAge
    }

    static func consume(
        packageFilePaths: Set<String>,
        packageFolderPaths: Set<String>
    ) -> PackageDropLoader.Payload? {
        guard Date().timeIntervalSince(startedAt) <= maxAge,
              let payload else { return nil }

        var dropPayload = PackageDropLoader.Payload()
        switch payload {
        case .file(let path) where packageFilePaths.contains(path):
            dropPayload.packageFilePaths.append(path)
        case .folder(let path) where packageFolderPaths.contains(path):
            dropPayload.packageFolderPaths.append(path)
        default:
            return nil
        }
        clear()
        return dropPayload
    }

    static func clear() {
        payload = nil
        startedAt = .distantPast
    }
}

extension UTType {
    nonisolated static let typesetPackageFileDrag = UTType(exportedAs: "com.twarge.typeset.package-file-drag", conformingTo: .json)
    nonisolated static let typesetPackageFolderDrag = UTType(exportedAs: "com.twarge.typeset.package-folder-drag", conformingTo: .json)
}

private extension PackageFile {
    var exportedContentType: UTType {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .data
    }
}


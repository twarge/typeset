// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UniformTypeIdentifiers

public extension UTType {
    static var typesetPackage: UTType {
        UTType("com.twarge.typeset.package")
            ?? UTType(filenameExtension: "typeset", conformingTo: .package)
            ?? .package
    }

    static var typstSource: UTType {
        UTType("com.typst.source")
            ?? UTType(filenameExtension: "typ", conformingTo: .text)
            ?? .text
    }
}

public enum TypesetPackageError: Error, Equatable {
    case noTypstFile
    case selectedFileMissing(String)
    case unsupportedFile(String)
    case invalidFolderName(String)
    case folderAlreadyExists(String)
    case invalidFileName(String)
    case fileAlreadyExists(String)
    case cannotMoveFolderIntoItself(String)
}

public struct PackageFile: Identifiable, Hashable, Sendable {
    public var path: String
    public var data: Data

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var isTypstSource: Bool { path.lowercased().hasSuffix(".typ") }
    public var isTextEditable: Bool {
        isTypstSource || path.lowercased().hasSuffix(".txt") || path.lowercased().hasSuffix(".md")
    }

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

public struct DocumentPackageState: Equatable, Sendable {
    public var selectedFile: String
    public var cursorLocation: Int
    public var cursorLength: Int
    /// Vertical scroll position of the editor for `selectedFile`, stored as a
    /// fraction (0...1) of the scrollable range so it survives reflow and window
    /// resizing on restore.
    public var scrollFraction: Double
    public var expandedFolders: [String]
    public var isSidebarVisible: Bool
    /// Preview viewport, capturing the exact zoomed location the user was
    /// looking at. `previewScale` is the PDF `scaleFactor` (`0` = no stored zoom,
    /// use automatic fit-to-width); `previewPage`/`previewPointX`/`previewPointY`
    /// are the top-left of the visible area as a `PDFDestination` (page index +
    /// point in page coordinates).
    public var previewScale: Double
    public var previewPage: Int
    public var previewPointX: Double
    public var previewPointY: Double
    /// Raw value of the workspace view mode (source/preview/both). Empty means
    /// "no stored preference" — the app falls back to its default.
    public var viewMode: String
    /// Raw value of the selected sidebar tab (files/outline/figures/references).
    /// Empty means "no stored preference".
    public var sidebarTab: String
    /// Package-relative path of the compile target as stored in the state
    /// file. `nil` means "not stored" — the package falls back to the legacy
    /// `.typeset` metadata file and then to the main Typst source.
    public var compileTarget: String?

    public init(
        selectedFile: String = "",
        cursorLocation: Int = 0,
        cursorLength: Int = 0,
        scrollFraction: Double = 0,
        expandedFolders: [String] = [],
        isSidebarVisible: Bool = false,
        previewScale: Double = 0,
        previewPage: Int = 0,
        previewPointX: Double = 0,
        previewPointY: Double = 0,
        viewMode: String = "",
        sidebarTab: String = "",
        compileTarget: String? = nil
    ) {
        self.selectedFile = selectedFile
        self.cursorLocation = max(0, cursorLocation)
        self.cursorLength = max(0, cursorLength)
        self.scrollFraction = Self.clampedFraction(scrollFraction)
        self.expandedFolders = Array(Set(expandedFolders)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        self.isSidebarVisible = isSidebarVisible
        self.previewScale = (previewScale.isFinite && previewScale > 0) ? previewScale : 0
        self.previewPage = max(0, previewPage)
        self.previewPointX = previewPointX.isFinite ? previewPointX : 0
        self.previewPointY = previewPointY.isFinite ? previewPointY : 0
        self.viewMode = viewMode
        self.sidebarTab = sidebarTab
        self.compileTarget = compileTarget
    }

    static func clampedFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }
}

public struct DocumentPackage: Equatable, Sendable {
    /// Obsolete standalone compile-target file from earlier versions. Never
    /// read or written anymore — only skipped, so stale copies don't appear
    /// as package files (and disappear on the next save).
    private static let legacyMetadataFileName = ".typeset"
    private static let stateFileName = ".typesetstate"
    private static let gitignoreFileName = ".gitignore"

    public var files: [PackageFile]
    public var folders: [String]
    public var selectedPath: String
    public var compileTargetPath: String
    public var state: DocumentPackageState

    /// The editor state exactly as decoded from a persisted state file, or
    /// `nil` when the package was loaded without one. Restore-on-open flows
    /// read this instead of `state`, which is live and may already reflect
    /// editor activity from the current session.
    public private(set) var persistedState: DocumentPackageState?

    public init(
        files: [PackageFile] = DocumentPackage.defaultFiles(),
        folders: [String] = [],
        selectedPath: String? = nil,
        compileTargetPath: String? = nil,
        state: DocumentPackageState = DocumentPackageState()
    ) throws {
        let sortedFiles = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let sortedFolders = Self.normalizedFolders(
            folders + Self.parentFolders(for: folders) + Self.parentFolders(for: sortedFiles)
        )
        guard sortedFiles.contains(where: \.isTypstSource) else {
            throw TypesetPackageError.noTypstFile
        }
        let stateSelectedPath = sortedFiles.contains(where: { $0.path == state.selectedFile }) ? state.selectedFile : nil
        let mainFile = selectedPath ?? stateSelectedPath ?? sortedFiles.first(where: \.isTypstSource)?.path ?? sortedFiles[0].path

        self.files = sortedFiles
        self.folders = sortedFolders
        self.selectedPath = mainFile
        self.compileTargetPath = Self.resolvedCompileTarget(from: sortedFiles, preferredPath: compileTargetPath)
        self.state = DocumentPackageState(
            selectedFile: mainFile,
            cursorLocation: state.cursorLocation,
            cursorLength: state.cursorLength,
            scrollFraction: state.scrollFraction,
            expandedFolders: state.expandedFolders.filter { sortedFolders.contains($0) },
            isSidebarVisible: state.isSidebarVisible,
            previewScale: state.previewScale,
            previewPage: state.previewPage,
            previewPointX: state.previewPointX,
            previewPointY: state.previewPointY,
            viewMode: state.viewMode,
            sidebarTab: state.sidebarTab
        )
    }

    public static func defaultFiles() -> [PackageFile] {
        let source = """
        = Typeset

        Typst is a document creation language.

        Typeset is a macOS application that compiles and displays Typst files. It is free and open source.

        #columns(2)[

        == Math

        Using mostly-familiar markup language:

        #set math.equation(numbering: "(1)")

        $ sum_(k=0)^n k
            &= 1 + ... + n \\
            &= (n(n+1)) / 2 $ <reference>

        It's easy to point back to @reference using \\@ references.

        == Units

        #import "@preview/unify:0.8.1": num,qty,numrange,qtyrange

        $ δ B = qty("14+2-5", "fT/Hz^0.5") $

        == Diagrams

        #import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
        #import fletcher.shapes: diamond

        #diagram(
            node-stroke: 1pt,
            node((0,0), [Should I stand \\ near this thing?],
                    corner-radius: 2pt, extrude: (0, 3)),
            edge("-|>"),
            node((0,1), [Are \\ physicists excited \\ about it?],
                    shape: diamond),
            edge("-|>", [No]),
            edge("d","-|>", [Yes]),
            node((1,1), [Maybe]),
            node((0,2), [No]),
        )

        from https://xkcd.com/2662/

        == Finite automata

        #{
            import "@preview/finite:0.5.1": automaton
            automaton(
          (
            q0:       (q1: 0, q0: "0,1"),
            q1:       (q0: (0, 1), q2: "0"),
            q2:       none,
          ),
          initial: "q1",
          final: ("q0",),
        )
        }

        == Chemistry

        #import "@preview/typed-smiles:0.4.0": smiles, ce, rxn-arrow, mol, reaction

        #{
        reaction(
              mol(smiles("C1=CC=CC=C1"), label: [benzene]),
              rxn-arrow(above: ce("Br2"), below: ce("FeBr3")),
              mol(smiles("BrC1=CC=CC=C1"), label: [bromobenzene])
        )
        }

        == Quantum circuits

        #{
          import "@preview/quill:0.7.2": *
          quantum-circuit(
            lstick($|0〉$), $H$, ctrl(1), rstick($(|00〉+|11〉)/√2$, n: 2), [\\ ],
            lstick($|0〉$), 1, targ(), 1
          )
        }

        == Timelines

        #import "@preview/timeliney:0.4.0"

        #timeliney.timeline(
        show-grid: true,
        {
           import timeliney: *
            headerline(group(([Year 1], 4)), group(([Year 2], 2)))

           headerline(
              group(..range(4).map(n => strong("Q" + str(n + 1)))),
              group(..range(2).map(n => strong("Q" + str(n + 1)))),
            )

            taskgroup(
                title: [*Research*],
              {
                task("Research", (from:0, to: 2))
                task("Develop", (from:2, to: 4))
                task("Report", (from:4, to: 6))
              }
           )

            milestone(at: 5.75, [Test])
        }
        )

        == Graphs

        #import "@preview/lilaq:0.6.0" as lq

        #let xs = lq.linspace(0, 3, num: 80)
        #lq.diagram(
          title: [Distribution],
          xlabel: $x$,
          ylabel: $y$,
        lq.plot(
            xs,
            xs.map(x => x*x*calc.exp(-x*x*1.3)),),
        )

        ]

        == Packages

        Typeset can save a package that contains multiple `.typ` files, images, and other compilation assets. Try dragging assets into the sidebar or the text. You can "Open Package Contents" in the Finder or remove the .typeset extension to reveal the source files.
        """
        return [PackageFile(path: "main.typ", data: Data(source.utf8))]
    }

    /// A single empty `main.typ`, used for new documents when the user turns off
    /// sample content in Settings. A package must contain at least one Typst
    /// source file, so an empty `main.typ` is the minimal valid blank document.
    public static func emptyFiles() -> [PackageFile] {
        [PackageFile(path: "main.typ", data: Data())]
    }

    public var selectedFile: PackageFile? {
        files.first { $0.path == selectedPath }
    }

    public var mainTypstPath: String? {
        Self.resolvedCompileTarget(from: files, preferredPath: compileTargetPath)
    }

    public var allFolderPaths: [String] {
        Self.normalizedFolders(folders + Self.parentFolders(for: folders) + Self.parentFolders(for: files))
    }

    public mutating func select(path: String, resettingEditorState: Bool = true) throws {
        guard files.contains(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }
        selectedPath = path
        if resettingEditorState {
            state.selectedFile = path
            state.cursorLocation = 0
            state.cursorLength = 0
            // A different file scrolls back to the top.
            state.scrollFraction = 0
        } else {
            state.selectedFile = path
        }
    }

    public mutating func updateEditorState(selectedFile: String, cursorLocation: Int, cursorLength: Int) throws {
        guard files.contains(where: { $0.path == selectedFile }) else {
            throw TypesetPackageError.selectedFileMissing(selectedFile)
        }

        // The scroll position only makes sense for the file it was captured in.
        let preservedScroll = state.selectedFile == selectedFile ? state.scrollFraction : 0
        selectedPath = selectedFile
        state = DocumentPackageState(
            selectedFile: selectedFile,
            cursorLocation: cursorLocation,
            cursorLength: cursorLength,
            scrollFraction: preservedScroll,
            expandedFolders: state.expandedFolders,
            isSidebarVisible: state.isSidebarVisible,
            previewScale: state.previewScale,
            previewPage: state.previewPage,
            previewPointX: state.previewPointX,
            previewPointY: state.previewPointY,
            viewMode: state.viewMode,
            sidebarTab: state.sidebarTab
        )
    }

    public mutating func updateScrollFraction(_ fraction: Double) {
        state.scrollFraction = DocumentPackageState.clampedFraction(fraction)
    }

    public mutating func updatePreviewViewport(scale: Double, page: Int, pointX: Double, pointY: Double) {
        state.previewScale = (scale.isFinite && scale > 0) ? scale : 0
        state.previewPage = max(0, page)
        state.previewPointX = pointX.isFinite ? pointX : 0
        state.previewPointY = pointY.isFinite ? pointY : 0
    }

    public mutating func updateViewMode(_ viewMode: String) {
        state.viewMode = viewMode
    }

    public mutating func updateSidebarTab(_ tab: String) {
        state.sidebarTab = tab
    }

    public mutating func updateExpandedFolders(_ expandedFolders: [String]) {
        state.expandedFolders = Array(Set(expandedFolders.filter { allFolderPaths.contains($0) })).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    public mutating func updateSidebarVisibility(_ isVisible: Bool) {
        state.isSidebarVisible = isVisible
    }

    public mutating func updateSelectedText(_ text: String) throws {
        try updateText(text, for: selectedPath)
    }

    public mutating func updateText(_ text: String, for path: String) throws {
        guard let index = files.firstIndex(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }
        guard files[index].isTextEditable else {
            throw TypesetPackageError.unsupportedFile(path)
        }
        files[index].data = Data(text.utf8)
    }

    /// Replaces a file's raw bytes regardless of whether it is text-editable.
    /// Used when mirroring an external on-disk change for any file (including
    /// binary assets) into the in-memory package.
    public mutating func updateFileData(_ data: Data, for path: String) throws {
        guard let index = files.firstIndex(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }
        files[index].data = data
    }

    public mutating func createFolder(named name: String, in parentPath: String? = nil) throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPathComponent(cleanName) else {
            throw TypesetPackageError.invalidFolderName(name)
        }

        let parent = Self.normalizedFolderPath(parentPath ?? "")
        let path = parent.isEmpty ? cleanName : "\(parent)/\(cleanName)"
        guard !allFolderPaths.contains(path) else {
            throw TypesetPackageError.folderAlreadyExists(path)
        }

        folders = Self.normalizedFolders(folders + [path])
        return path
    }

    public mutating func addFile(named name: String, data: Data, in folderPath: String? = nil) throws -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPathComponent(cleanName) else {
            throw TypesetPackageError.invalidFileName(name)
        }

        let folder = Self.normalizedFolderPath(folderPath ?? "")
        let path = uniqueFilePath(named: cleanName, in: folder)
        files.append(PackageFile(path: path, data: data))
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        folders = Self.normalizedFolders(folders + Self.parentFolders(for: files))
        return path
    }

    public mutating func moveFile(
        at sourcePath: String,
        toFolder destinationFolder: String?,
        updatingReferences: Bool = false
    ) throws -> String {
        guard let index = files.firstIndex(where: { $0.path == sourcePath }) else {
            throw TypesetPackageError.selectedFileMissing(sourcePath)
        }

        let folder = Self.normalizedFolderPath(destinationFolder ?? "")
        if !folder.isEmpty, !allFolderPaths.contains(folder) {
            throw TypesetPackageError.selectedFileMissing(folder)
        }
        let name = files[index].name
        let destinationPath = folder.isEmpty ? name : "\(folder)/\(name)"
        guard destinationPath != sourcePath else { return sourcePath }
        guard !files.contains(where: { $0.path == destinationPath }) else {
            throw TypesetPackageError.fileAlreadyExists(destinationPath)
        }

        updateCompileTargetAfterMoving(sourcePath: sourcePath, destinationPath: destinationPath)
        files[index].path = destinationPath
        sortAndNormalize()
        updateSelectionAfterMoving(sourcePath: sourcePath, destinationPath: destinationPath)
        if updatingReferences {
            updateFileReferences(for: [(sourcePath, destinationPath)])
        }
        return destinationPath
    }

    public mutating func moveFolder(
        at sourcePath: String,
        toFolder destinationFolder: String?,
        updatingReferences: Bool = false
    ) throws -> String {
        let folderPath = Self.normalizedFolderPath(sourcePath)
        guard allFolderPaths.contains(folderPath) else {
            throw TypesetPackageError.selectedFileMissing(sourcePath)
        }
        let affectedOldPaths = files
            .map(\.path)
            .filter { $0.hasPrefix(folderPath + "/") }

        let destinationFolder = Self.normalizedFolderPath(destinationFolder ?? "")
        if !destinationFolder.isEmpty, !allFolderPaths.contains(destinationFolder) {
            throw TypesetPackageError.selectedFileMissing(destinationFolder)
        }
        if destinationFolder == folderPath {
            return folderPath
        }
        if destinationFolder.hasPrefix(folderPath + "/") {
            throw TypesetPackageError.cannotMoveFolderIntoItself(folderPath)
        }

        let name = URL(fileURLWithPath: folderPath).lastPathComponent
        let destinationPath = destinationFolder.isEmpty ? name : "\(destinationFolder)/\(name)"
        guard destinationPath != folderPath else { return folderPath }
        guard !allFolderPaths.contains(destinationPath) else {
            throw TypesetPackageError.folderAlreadyExists(destinationPath)
        }
        guard !files.contains(where: { $0.path == destinationPath }) else {
            throw TypesetPackageError.fileAlreadyExists(destinationPath)
        }

        folders = allFolderPaths.map {
            Self.pathByReplacingPrefix($0, sourcePrefix: folderPath, destinationPrefix: destinationPath)
        }
        for index in files.indices where files[index].path.hasPrefix(folderPath + "/") {
            files[index].path = Self.pathByReplacingPrefix(
                files[index].path,
                sourcePrefix: folderPath,
                destinationPrefix: destinationPath
            )
        }
        updateCompileTargetAfterMoving(sourcePath: folderPath, destinationPath: destinationPath)
        updateSelectionAfterMoving(sourcePath: folderPath, destinationPath: destinationPath)
        sortAndNormalize()
        if updatingReferences {
            updateFileReferences(
                for: affectedOldPaths.map {
                    ($0, Self.pathByReplacingPrefix($0, sourcePrefix: folderPath, destinationPrefix: destinationPath))
                }
            )
        }
        return destinationPath
    }

    public mutating func renameFile(
        at path: String,
        to name: String,
        updatingReferences: Bool = false
    ) throws -> String {
        guard let index = files.firstIndex(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPathComponent(cleanName) else {
            throw TypesetPackageError.invalidFileName(name)
        }

        let folder = Self.parentFolder(forFilePath: path)
        let newPath = folder.isEmpty ? cleanName : "\(folder)/\(cleanName)"
        guard newPath != path else { return path }
        guard !files.contains(where: { $0.path == newPath }) else {
            throw TypesetPackageError.fileAlreadyExists(newPath)
        }

        updateCompileTargetAfterMoving(sourcePath: path, destinationPath: newPath)
        files[index].path = newPath
        sortAndNormalize()
        updateSelectionAfterMoving(sourcePath: path, destinationPath: newPath)
        if updatingReferences {
            updateFileReferences(for: [(path, newPath)])
        }
        return newPath
    }

    public mutating func renameFolder(
        at path: String,
        to name: String,
        updatingReferences: Bool = false
    ) throws -> String {
        let folderPath = Self.normalizedFolderPath(path)
        guard allFolderPaths.contains(folderPath) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }
        let affectedOldPaths = files
            .map(\.path)
            .filter { $0.hasPrefix(folderPath + "/") }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidPathComponent(cleanName) else {
            throw TypesetPackageError.invalidFolderName(name)
        }

        let parent = Self.parentFolder(forFolderPath: folderPath)
        let newPath = parent.isEmpty ? cleanName : "\(parent)/\(cleanName)"
        guard newPath != folderPath else { return folderPath }
        guard !allFolderPaths.contains(newPath) else {
            throw TypesetPackageError.folderAlreadyExists(newPath)
        }
        guard !files.contains(where: { $0.path == newPath }) else {
            throw TypesetPackageError.fileAlreadyExists(newPath)
        }

        folders = allFolderPaths.map {
            Self.pathByReplacingPrefix($0, sourcePrefix: folderPath, destinationPrefix: newPath)
        }
        for index in files.indices where files[index].path.hasPrefix(folderPath + "/") {
            files[index].path = Self.pathByReplacingPrefix(
                files[index].path,
                sourcePrefix: folderPath,
                destinationPrefix: newPath
            )
        }
        updateCompileTargetAfterMoving(sourcePath: folderPath, destinationPath: newPath)
        updateSelectionAfterMoving(sourcePath: folderPath, destinationPath: newPath)
        sortAndNormalize()
        if updatingReferences {
            updateFileReferences(
                for: affectedOldPaths.map {
                    ($0, Self.pathByReplacingPrefix($0, sourcePrefix: folderPath, destinationPrefix: newPath))
                }
            )
        }
        return newPath
    }

    public mutating func deleteFile(at path: String) throws {
        guard let index = files.firstIndex(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }

        let removedFile = files.remove(at: index)
        guard files.contains(where: \.isTypstSource) else {
            files.insert(removedFile, at: index)
            throw TypesetPackageError.noTypstFile
        }

        sortAndNormalize()
        if selectedPath == path {
            selectedPath = compileTargetPath
            state.selectedFile = selectedPath
            state.cursorLocation = 0
            state.cursorLength = 0
        }
        if state.selectedFile == path {
            state.selectedFile = selectedPath
            state.cursorLocation = 0
            state.cursorLength = 0
        }
    }

    public mutating func deleteFolder(at path: String) throws {
        let folderPath = Self.normalizedFolderPath(path)
        guard allFolderPaths.contains(folderPath) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }

        let remainingFiles = files.filter { !$0.path.hasPrefix(folderPath + "/") }
        guard remainingFiles.contains(where: \.isTypstSource) else {
            throw TypesetPackageError.noTypstFile
        }

        files = remainingFiles
        folders = allFolderPaths.filter { folder in
            folder != folderPath && !folder.hasPrefix(folderPath + "/")
        }
        state.expandedFolders.removeAll { folder in
            folder == folderPath || folder.hasPrefix(folderPath + "/")
        }
        sortAndNormalize()

        if selectedPath.hasPrefix(folderPath + "/") || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = compileTargetPath
            state.selectedFile = selectedPath
            state.cursorLocation = 0
            state.cursorLength = 0
        }
        if state.selectedFile.hasPrefix(folderPath + "/") || !files.contains(where: { $0.path == state.selectedFile }) {
            state.selectedFile = selectedPath
            state.cursorLocation = 0
            state.cursorLength = 0
        }
    }

    public mutating func setCompileTarget(path: String) throws {
        guard files.contains(where: { $0.path == path && $0.isTypstSource }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }

        compileTargetPath = path
    }

    public func text(for path: String) -> String {
        guard let file = files.first(where: { $0.path == path }) else { return "" }
        return String(decoding: file.data, as: UTF8.self)
    }

    private static func normalizedFolders(_ paths: [String]) -> [String] {
        Array(Set(paths.compactMap { path in
            let normalized = normalizedFolderPath(path)
            return normalized.isEmpty ? nil : normalized
        }))
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalizedFolderPath(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .joined(separator: "/")
    }

    private static func isValidPathComponent(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    private static func parentFolder(forFilePath path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    private static func parentFolder(forFolderPath path: String) -> String {
        parentFolder(forFilePath: path)
    }

    private static func pathByReplacingPrefix(_ path: String, sourcePrefix: String, destinationPrefix: String) -> String {
        if path == sourcePrefix {
            return destinationPrefix
        }
        if path.hasPrefix(sourcePrefix + "/") {
            let suffix = path.dropFirst(sourcePrefix.count + 1)
            return destinationPrefix.isEmpty ? String(suffix) : "\(destinationPrefix)/\(suffix)"
        }
        return path
    }

    private mutating func updateFileReferences(for moves: [(oldPath: String, newPath: String)]) {
        guard !moves.isEmpty else { return }

        for index in files.indices where files[index].isTextEditable {
            let original = String(decoding: files[index].data, as: UTF8.self)
            var updated = original
            for (oldPath, newPath) in moves where oldPath != newPath {
                updated = updated.replacingOccurrences(of: "\"\(oldPath)\"", with: "\"\(newPath)\"")
                let oldParent = (oldPath as NSString).deletingLastPathComponent
                let newParent = (newPath as NSString).deletingLastPathComponent
                let oldName = (oldPath as NSString).lastPathComponent
                let newName = (newPath as NSString).lastPathComponent
                if oldParent == newParent && oldName != newName {
                    updated = updated.replacingOccurrences(of: "\"\(oldName)\"", with: "\"\(newName)\"")
                }
            }

            if updated != original {
                files[index].data = Data(updated.utf8)
            }
        }
    }

    private mutating func sortAndNormalize() {
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        folders = Self.normalizedFolders(folders + Self.parentFolders(for: files))
        compileTargetPath = Self.resolvedCompileTarget(from: files, preferredPath: compileTargetPath)
    }

    private mutating func updateSelectionAfterMoving(sourcePath: String, destinationPath: String) {
        selectedPath = Self.pathByReplacingPrefix(selectedPath, sourcePrefix: sourcePath, destinationPrefix: destinationPath)
        state.selectedFile = Self.pathByReplacingPrefix(state.selectedFile, sourcePrefix: sourcePath, destinationPrefix: destinationPath)
        state.expandedFolders = state.expandedFolders.map { folder in
            Self.pathByReplacingPrefix(folder, sourcePrefix: sourcePath, destinationPrefix: destinationPath)
        }
    }

    private mutating func updateCompileTargetAfterMoving(sourcePath: String, destinationPath: String) {
        compileTargetPath = Self.pathByReplacingPrefix(compileTargetPath, sourcePrefix: sourcePath, destinationPrefix: destinationPath)
    }

    private static func resolvedCompileTarget(from files: [PackageFile], preferredPath: String?) -> String {
        if let preferredPath,
           files.contains(where: { $0.path == preferredPath && $0.isTypstSource }) {
            return preferredPath
        }

        return files.first { $0.path == "main.typ" }?.path ?? files.first(where: \.isTypstSource)?.path ?? ""
    }

    private func uniqueFilePath(named name: String, in folder: String) -> String {
        func path(for candidate: String) -> String {
            folder.isEmpty ? candidate : "\(folder)/\(candidate)"
        }

        let existingPaths = Set(files.map(\.path))
        let originalPath = path(for: name)
        guard existingPaths.contains(originalPath) else { return originalPath }

        let nsName = name as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension

        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidatePath = path(for: candidateName)
            if !existingPaths.contains(candidatePath) {
                return candidatePath
            }
            index += 1
        }
    }

    private static func parentFolders(for files: [PackageFile]) -> [String] {
        files.flatMap { file -> [String] in
            let parts = file.path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { return [] }

            return (1..<parts.count).map { depth in
                parts.prefix(depth).joined(separator: "/")
            }
        }
    }

    private static func parentFolders(for folders: [String]) -> [String] {
        folders.flatMap { folder -> [String] in
            let parts = folder.split(separator: "/").map(String.init)
            guard parts.count > 1 else { return [] }

            return (1..<parts.count).map { depth in
                parts.prefix(depth).joined(separator: "/")
            }
        }
    }
}

extension TypesetPackageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noTypstFile:
            return "The package does not contain a Typst source file."
        case .selectedFileMissing(let path):
            return "The selected file could not be found: \(path)"
        case .unsupportedFile(let path):
            return "Typeset cannot edit this file type yet: \(path)"
        case .invalidFolderName(let name):
            return "“\(name)” is not a valid folder name."
        case .folderAlreadyExists(let path):
            return "A folder already exists at \(path)."
        case .invalidFileName(let name):
            return "“\(name)” is not a valid file name."
        case .fileAlreadyExists(let path):
            return "A file already exists at \(path)."
        case .cannotMoveFolderIntoItself(let path):
            return "Cannot move \(path) into itself."
        }
    }
}

public extension DocumentPackage {
    init(directoryURL: URL, openedFileURL: URL) throws {
        let directoryURL = directoryURL.standardizedFileURL
        let openedFileURL = openedFileURL.standardizedFileURL
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey]
        let contents = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        )

        var files: [PackageFile] = []
        var folders: [String] = []
        var state: DocumentPackageState?

        for url in contents {
            try Self.collectDirectoryEntry(
                url: url,
                rootURL: directoryURL,
                files: &files,
                folders: &folders,
                state: &state
            )
        }

        let openedPath = Self.relativePackagePath(for: openedFileURL, rootURL: directoryURL)
        try self.init(
            files: files,
            folders: folders,
            selectedPath: openedPath,
            // A compile target persisted in the folder's state file wins over
            // the opened file, so opening a chapter still compiles the
            // document root.
            compileTargetPath: state?.compileTarget ?? openedPath,
            state: state ?? DocumentPackageState(selectedFile: openedPath)
        )
        persistedState = state
    }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory, let wrappers = fileWrapper.fileWrappers else {
            throw TypesetPackageError.noTypstFile
        }

        let entries = Self.flatten(wrappers: wrappers, prefix: "")
        try self.init(
            files: entries.files,
            folders: entries.folders,
            compileTargetPath: entries.state?.compileTarget,
            state: entries.state ?? DocumentPackageState()
        )
        persistedState = entries.state
    }

    func fileWrapper() -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])

        for folder in allFolderPaths {
            append(folderParts: folder.split(separator: "/").map(String.init), to: root)
        }

        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            append(file: file, parts: parts, to: root)
        }

        let state = FileWrapper(regularFileWithContents: Data(encodeState().utf8))
        state.preferredFilename = Self.stateFileName
        root.addFileWrapper(state)

        let gitignore = FileWrapper(regularFileWithContents: Data("\(Self.stateFileName)\n".utf8))
        gitignore.preferredFilename = Self.gitignoreFileName
        root.addFileWrapper(gitignore)

        return root
    }

    private static func flatten(wrappers: [String: FileWrapper], prefix: String) -> (files: [PackageFile], folders: [String], state: DocumentPackageState?) {
        wrappers.reduce(into: (files: [PackageFile](), folders: [String](), state: Optional<DocumentPackageState>.none)) { result, entry in
            let name = entry.key
            let wrapper = entry.value
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if prefix.isEmpty, name == Self.legacyMetadataFileName {
                // Obsolete standalone compile-target file; ignored, and
                // dropped from the package on the next save.
                return
            }
            if prefix.isEmpty, name == Self.stateFileName {
                result.state = Self.decodeState(from: wrapper.regularFileContents)
                return
            }
            if prefix.isEmpty, name == Self.gitignoreFileName {
                return
            }

            if wrapper.isDirectory, let children = wrapper.fileWrappers {
                result.folders.append(path)
                let flattened = flatten(wrappers: children, prefix: path)
                result.files.append(contentsOf: flattened.files)
                result.folders.append(contentsOf: flattened.folders)
                result.state = result.state ?? flattened.state
            } else {
                result.files.append(PackageFile(path: path, data: wrapper.regularFileContents ?? Data()))
            }
        }
    }

    private func encodeState() -> String {
        """
        selected_file = "\(Self.tomlEscaped(state.selectedFile))"
        cursor_location = \(max(0, state.cursorLocation))
        cursor_length = \(max(0, state.cursorLength))
        scroll_fraction = \(Self.tomlNumber(state.scrollFraction))
        expanded_folders = [\(state.expandedFolders.map { "\"\(Self.tomlEscaped($0))\"" }.joined(separator: ", "))]
        sidebar_visible = \(state.isSidebarVisible)
        preview_scale = \(String(format: "%.6f", max(0, state.previewScale)))
        preview_page = \(max(0, state.previewPage))
        preview_point_x = \(String(format: "%.4f", state.previewPointX))
        preview_point_y = \(String(format: "%.4f", state.previewPointY))
        view_mode = "\(Self.tomlEscaped(state.viewMode))"
        sidebar_tab = "\(Self.tomlEscaped(state.sidebarTab))"
        compile_target = "\(Self.tomlEscaped(compileTargetPath))"
        """
    }

    private static func tomlNumber(_ value: Double) -> String {
        // Stable, locale-independent, finite serialization.
        let clamped = DocumentPackageState.clampedFraction(value)
        return String(format: "%.6f", clamped)
    }

    private static func decodeState(from data: Data?) -> DocumentPackageState? {
        guard let data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var selectedFile = ""
        var cursorLocation = 0
        var cursorLength = 0
        var scrollFraction = 0.0
        var expandedFolders: [String] = []
        var isSidebarVisible = false
        var previewScale = 0.0
        var previewPage = 0
        var previewPointX = 0.0
        var previewPointY = 0.0
        var viewMode = ""
        var sidebarTab = ""
        var compileTarget: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "selected_file":
                selectedFile = tomlStringValue(value)
            case "cursor_location":
                cursorLocation = Int(value) ?? 0
            case "cursor_length":
                cursorLength = Int(value) ?? 0
            case "scroll_fraction":
                scrollFraction = Double(value) ?? 0
            case "expanded_folders":
                expandedFolders = tomlStringArrayValue(value)
            case "sidebar_visible":
                isSidebarVisible = tomlBoolValue(value)
            case "preview_scale":
                previewScale = Double(value) ?? 0
            case "preview_page":
                previewPage = Int(value) ?? 0
            case "preview_point_x":
                previewPointX = Double(value) ?? 0
            case "preview_point_y":
                previewPointY = Double(value) ?? 0
            case "view_mode":
                viewMode = tomlStringValue(value)
            case "sidebar_tab":
                sidebarTab = tomlStringValue(value)
            case "compile_target":
                let target = tomlStringValue(value)
                compileTarget = target.isEmpty ? nil : target
            default:
                continue
            }
        }

        return DocumentPackageState(
            selectedFile: selectedFile,
            cursorLocation: cursorLocation,
            cursorLength: cursorLength,
            scrollFraction: scrollFraction,
            expandedFolders: expandedFolders,
            isSidebarVisible: isSidebarVisible,
            previewScale: previewScale,
            previewPage: previewPage,
            previewPointX: previewPointX,
            previewPointY: previewPointY,
            viewMode: viewMode,
            sidebarTab: sidebarTab,
            compileTarget: compileTarget
        )
    }

    private static func tomlBoolValue(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private static func tomlEscaped(_ string: String) -> String {
        string.reduce(into: "") { result, character in
            switch character {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\t":
                result += "\\t"
            default:
                result.append(character)
            }
        }
    }

    private static func tomlStringValue(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return value
        }

        var result = ""
        var isEscaped = false
        for character in value.dropFirst().dropLast() {
            if isEscaped {
                switch character {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                default:
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func tomlStringArrayValue(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return []
        }

        let body = trimmed.dropFirst().dropLast()
        var values: [String] = []
        var current = ""
        var isInString = false
        var isEscaped = false

        for character in body {
            if isEscaped {
                current.append("\\")
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                current.append(character)
                isInString.toggle()
                continue
            }

            if character == ",", !isInString {
                let value = current.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    values.append(tomlStringValue(value))
                }
                current = ""
            } else {
                current.append(character)
            }
        }

        let value = current.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty {
            values.append(tomlStringValue(value))
        }
        return values
    }

    private static func collectDirectoryEntry(
        url: URL,
        rootURL: URL,
        files: inout [PackageFile],
        folders: inout [String],
        state: inout DocumentPackageState?
    ) throws {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let relativePath = relativePackagePath(for: url, rootURL: rootURL)
        let name = url.lastPathComponent

        if url.deletingLastPathComponent().standardizedFileURL == rootURL {
            if name == Self.legacyMetadataFileName {
                // Obsolete standalone compile-target file; ignored.
                return
            }
            if name == Self.stateFileName {
                state = decodeState(from: try? Data(contentsOf: url))
                return
            }
            if name == Self.gitignoreFileName {
                return
            }
        }

        if resourceValues.isDirectory == true {
            folders.append(relativePath)
            let children = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsPackageDescendants]
            )
            for child in children {
                try collectDirectoryEntry(
                    url: child,
                    rootURL: rootURL,
                    files: &files,
                    folders: &folders,
                    state: &state
                )
            }
        } else if resourceValues.isRegularFile == true {
            files.append(PackageFile(path: relativePath, data: try Data(contentsOf: url)))
        }
    }

    private static func relativePackagePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func append(folderParts parts: [String], to directory: FileWrapper) {
        guard let head = parts.first else { return }

        let existing = directory.fileWrappers?[head]
        let childDirectory: FileWrapper
        if let existing, existing.isDirectory {
            childDirectory = existing
        } else {
            childDirectory = FileWrapper(directoryWithFileWrappers: [:])
            childDirectory.preferredFilename = head
            directory.addFileWrapper(childDirectory)
        }

        append(folderParts: Array(parts.dropFirst()), to: childDirectory)
    }

    private func append(file: PackageFile, parts: [String], to directory: FileWrapper) {
        guard let head = parts.first else { return }

        if parts.count == 1 {
            let child = FileWrapper(regularFileWithContents: file.data)
            child.preferredFilename = head
            directory.addFileWrapper(child)
            return
        }

        let existing = directory.fileWrappers?[head]
        let childDirectory: FileWrapper
        if let existing, existing.isDirectory {
            childDirectory = existing
        } else {
            childDirectory = FileWrapper(directoryWithFileWrappers: [:])
            childDirectory.preferredFilename = head
            directory.addFileWrapper(childDirectory)
        }

        append(file: file, parts: Array(parts.dropFirst()), to: childDirectory)
    }
}

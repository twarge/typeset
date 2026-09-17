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
    /// A file existed in the package but its bytes could not be produced
    /// (an unmaterialized iCloud item, a failed lazy read). Opening must fail
    /// rather than substitute empty content, because a later save would write
    /// that emptiness over the real file.
    case unreadableFile(String)
    /// The file is a cloud item that has not been downloaded to this device.
    /// The folder loader no longer throws this — it skips such files and
    /// records them in `skippedFiles` — but the case stays for callers that
    /// surface it.
    case fileNotDownloaded(String)
    /// Saving was refused because it would write empty content over files that
    /// were loaded with content and never edited in this session.
    case saveWouldEraseContent([String])
}

/// A file present in the document's folder that could not be imported, with
/// the reason in user-facing terms. The package neither contains nor tracks
/// such a file, so a save never writes or removes it.
public struct SkippedFile: Hashable, Sendable {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct PackageFile: Identifiable, Hashable, Sendable {
    public var path: String
    public var data: Data

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var isTypstSource: Bool { path.lowercased().hasSuffix(".typ") }
    /// Plain-text formats the editor can open. Beyond prose, a package holds
    /// the data a document reads (`read`/`csv`/`json`) and the scripts that
    /// generate it, and those are worth editing in place rather than only
    /// through a preview.
    public static let editableTextExtensions: Set<String> = [
        "typ", "txt", "md", "py", "csv", "tsv", "json", "toml", "yaml", "yml", "bib",
    ]

    public var isTextEditable: Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return Self.editableTextExtensions.contains(fileExtension)
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

/// What a folder write-through may take off disk on a package's behalf. See
/// `DocumentPackage.mirrorRemovalPlan`.
public struct MirrorRemovalPlan: Equatable, Sendable {
    /// Files to remove.
    public var files: [String] = []
    /// Folders to remove, deepest first.
    public var folders: [String] = []
    /// Mirrored files and folders that are gone from the package but must
    /// stay on disk, because nothing shows this session meant to remove them.
    public var retained: [String] = []
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

    /// Byte count of every file as it was loaded from disk, keyed by package
    /// path. Empty for packages that were not loaded from disk (new documents,
    /// programmatic construction). `validateForSaving()` checks the current
    /// files against this baseline so a save can never erase content the
    /// session did not deliberately change.
    public private(set) var loadedByteCounts: [String: Int] = [:]

    /// Package paths whose bytes or location this session deliberately changed
    /// (edits, adds, moves, renames, deletes) — files, and the folders that
    /// were moved, renamed or deleted. Only these files may shrink to empty or
    /// disappear relative to `loadedByteCounts`, and only these need their
    /// bytes rewritten by an incremental save. Maintained by the mutating
    /// methods; mutating `files` directly bypasses it.
    public private(set) var changedPaths: Set<String> = []

    /// Files in the loaded folder that were left out because their bytes
    /// could not be read — a cloud placeholder that would not materialize, a
    /// stale entry whose content is gone. Empty unless loaded from a folder.
    public private(set) var skippedFiles: [SkippedFile] = []

    /// Files in the loaded folder whose content the cloud provider has not
    /// delivered to this device yet. The loader leaves them out rather than
    /// waiting on a download; the app requests them (see
    /// `CloudFileMaterializer`) and re-reads the folder once they arrive.
    public private(set) var pendingDownloads: [String] = []

    /// The directory this package mirrors on disk — the folder it was loaded
    /// from, or the `.typeset` bundle the document system persists it to —
    /// so a compile can read unchanged assets straight from disk instead of
    /// from a temporary copy. Set by the folder loader; the app sets it for
    /// a saved bundle. `nil` for a package that lives only in memory.
    public var onDiskRootURL: URL?

    // Change-tracking metadata is bookkeeping about the session, not part of
    // the package's value: two packages with the same contents are equal even
    // if they were loaded or edited differently.
    public static func == (lhs: DocumentPackage, rhs: DocumentPackage) -> Bool {
        lhs.files == rhs.files
            && lhs.folders == rhs.folders
            && lhs.selectedPath == rhs.selectedPath
            && lhs.compileTargetPath == rhs.compileTargetPath
            && lhs.state == rhs.state
            && lhs.persistedState == rhs.persistedState
    }

    /// Marks the package's current contents as the on-disk truth: records every
    /// file's byte count as the save-validation baseline and clears the
    /// changed-path tracking. The disk-loading initializers call this; call it
    /// directly only when the in-memory package is known to exactly match what
    /// was just read from disk.
    public mutating func recordLoadedBaseline() {
        loadedByteCounts = Dictionary(
            files.map { ($0.path, $0.data.count) },
            uniquingKeysWith: { first, _ in first }
        )
        changedPaths = []
    }

    /// Refuses a save that would destroy data the session never touched. A file
    /// loaded from disk with content may only be written back empty if an edit
    /// in this session deliberately made it so. Anything else means the
    /// in-memory package no longer faithfully represents what was read — for
    /// example an incomplete iCloud materialization — and writing it out would
    /// erase the on-disk original.
    public func validateForSaving() throws {
        guard !loadedByteCounts.isEmpty else { return }
        let currentSizes = Dictionary(
            files.map { ($0.path, $0.data.count) },
            uniquingKeysWith: { first, _ in first }
        )
        let erased = loadedByteCounts
            .filter { path, byteCount in
                byteCount > 0 && !changedPaths.contains(path) && currentSizes[path, default: 0] == 0
            }
            .keys
            .sorted()
        guard erased.isEmpty else {
            throw TypesetPackageError.saveWouldEraseContent(erased)
        }
    }

    /// Decides which previously mirrored items a folder write-through may
    /// take off disk now that they are gone from the package. Absence alone is
    /// not intent: the document system can swap in a package that never knew
    /// the folder (Revert re-reads only the opened `.typ`), and an undo can
    /// restore one that predates files another program has added since. So an
    /// item goes only when this package records its removal (`changedPaths`)
    /// or the write-through itself put it on disk (`createdByMirror` — what
    /// lets undoing an in-app create take the file back off disk). Everything
    /// else is retained, for the caller to fold back into the package.
    public func mirrorRemovalPlan(
        mirroredFiles: Set<String>,
        mirroredFolders: Set<String>,
        createdByMirror: Set<String>
    ) -> MirrorRemovalPlan {
        var plan = MirrorRemovalPlan()
        let missingFiles = mirroredFiles.subtracting(files.map(\.path)).sorted()
        let missingFolders = mirroredFolders.subtracting(allFolderPaths)
            .sorted { $0.count > $1.count }

        // A package that was not loaded from a folder mirrors nothing, so
        // nothing may be removed on its behalf.
        guard onDiskRootURL != nil else {
            plan.retained = missingFiles + missingFolders
            return plan
        }

        for path in missingFiles {
            if changedPaths.contains(path) || createdByMirror.contains(path) {
                plan.files.append(path)
            } else {
                plan.retained.append(path)
            }
        }
        // Removing a folder takes everything inside along, so beyond being
        // meant it must hold nothing retained. Deepest first: a retained
        // subfolder pins its ancestors too.
        for folder in missingFolders {
            let isMeant = changedPaths.contains(folder) || createdByMirror.contains(folder)
            let holdsRetained = plan.retained.contains { $0.hasPrefix(folder + "/") }
            if isMeant && !holdsRetained {
                plan.folders.append(folder)
            } else {
                plan.retained.append(folder)
            }
        }
        return plan
    }

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

        Typeset can save a package that contains multiple `.typ` files, images, fonts, and other compilation assets. Try dragging assets into the sidebar or the text. A font file (`.ttf`, `.otf`, `.ttc`, or `.otc`) added anywhere in the package becomes available to `#set text(font: ...)` automatically. You can "Open Package Contents" in the Finder or remove the .typeset extension to reveal the source files.
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
        changedPaths.insert(path)
    }

    /// Replaces a file's raw bytes regardless of whether it is text-editable.
    /// Used when mirroring an external on-disk change for any file (including
    /// binary assets) into the in-memory package.
    public mutating func updateFileData(_ data: Data, for path: String) throws {
        guard let index = files.firstIndex(where: { $0.path == path }) else {
            throw TypesetPackageError.selectedFileMissing(path)
        }
        files[index].data = data
        changedPaths.insert(path)
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
        changedPaths.insert(path)
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
        changedPaths.insert(sourcePath)
        changedPaths.insert(destinationPath)
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

        recordFolderChange(at: folderPath, movedTo: destinationPath)
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
        for oldPath in affectedOldPaths {
            changedPaths.insert(oldPath)
            changedPaths.insert(Self.pathByReplacingPrefix(oldPath, sourcePrefix: folderPath, destinationPrefix: destinationPath))
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
        changedPaths.insert(path)
        changedPaths.insert(newPath)
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

        recordFolderChange(at: folderPath, movedTo: newPath)
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
        for oldPath in affectedOldPaths {
            changedPaths.insert(oldPath)
            changedPaths.insert(Self.pathByReplacingPrefix(oldPath, sourcePrefix: folderPath, destinationPrefix: newPath))
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

        changedPaths.insert(path)
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

        for file in files where file.path.hasPrefix(folderPath + "/") {
            changedPaths.insert(file.path)
        }
        recordFolderChange(at: folderPath, movedTo: nil)
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
                changedPaths.insert(files[index].path)
            }
        }
    }

    /// Records a folder and its subfolders as deliberately deleted (or moved
    /// to `destinationPath`). Files carry their own entries; this covers the
    /// folders themselves, so removing even an empty one counts as intent.
    /// Call before `folders` is rewritten.
    private mutating func recordFolderChange(at folderPath: String, movedTo destinationPath: String?) {
        for folder in allFolderPaths where folder == folderPath || folder.hasPrefix(folderPath + "/") {
            changedPaths.insert(folder)
            if let destinationPath {
                changedPaths.insert(
                    Self.pathByReplacingPrefix(folder, sourcePrefix: folderPath, destinationPrefix: destinationPath)
                )
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
        case .unreadableFile(let path):
            return "“\(path)” could not be read. The document was left untouched — check that it has finished downloading from iCloud, then try opening it again."
        case .fileNotDownloaded(let path):
            return "“\(path)” has not finished downloading from its cloud service. Its download has been requested — try opening the document again once it is available on this device."
        case .saveWouldEraseContent(let paths):
            let listed = paths.prefix(5).map { "“\($0)”" }.joined(separator: ", ")
            let suffix = paths.count > 5 ? " and \(paths.count - 5) more" : ""
            return "Saving was stopped because it would have erased \(listed)\(suffix), which had content when the document was opened but was never edited here. The document may not have been fully readable when it was opened — close it without saving and reopen it."
        }
    }
}

public extension DocumentPackage {
    init(directoryURL: URL, openedFileURL: URL, openedFileIsAuthoritative: Bool = false) throws {
        let directoryURL = directoryURL.standardizedFileURL
        let openedFileURL = openedFileURL.standardizedFileURL

        // Read the folder under file coordination so an in-flight iCloud sync
        // or another writer finishes before we snapshot it, rather than
        // capturing a half-written state.
        var files: [PackageFile] = []
        var folders: [String] = []
        var skipped: [SkippedFile] = []
        var pending: [String] = []
        var state: DocumentPackageState?
        var collectionError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: directoryURL,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: coordinatedURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey],
                    options: [.skipsPackageDescendants]
                )
                for url in contents {
                    try Self.collectDirectoryEntry(
                        url: url,
                        rootURL: coordinatedURL.standardizedFileURL,
                        files: &files,
                        folders: &folders,
                        skipped: &skipped,
                        pending: &pending,
                        state: &state
                    )
                }
            } catch {
                collectionError = error
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        if let collectionError {
            throw collectionError
        }

        let openedPath = Self.relativePackagePath(for: openedFileURL, rootURL: directoryURL)

        if openedFileIsAuthoritative {
            // Opening a file directly makes THAT file both the selection and the
            // compile target, regardless of what the folder's `.typesetstate`
            // recorded. When the state was saved for a different file or compile
            // target, its remaining settings (scroll, zoom, view mode, sidebar,
            // expanded folders) belong to a different context, so drop them
            // entirely and open the file fresh.
            let stateMatchesOpenedFile =
                state?.selectedFile == openedPath && state?.compileTarget == openedPath
            let keptState = stateMatchesOpenedFile ? state : nil
            try self.init(
                files: files,
                folders: folders,
                selectedPath: openedPath,
                compileTargetPath: openedPath,
                state: keptState ?? DocumentPackageState(selectedFile: openedPath)
            )
            persistedState = keptState
            recordLoadedBaseline()
        } else {
            try self.init(
                files: files,
                folders: folders,
                selectedPath: openedPath,
                // A compile target persisted in the folder's state file wins
                // over the opened file, so a watcher re-read keeps the chosen
                // target.
                compileTargetPath: state?.compileTarget ?? openedPath,
                state: state ?? DocumentPackageState(selectedFile: openedPath)
            )
            persistedState = state
            recordLoadedBaseline()
        }
        skippedFiles = skipped.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        pendingDownloads = pending.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        onDiskRootURL = directoryURL
    }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory, let wrappers = fileWrapper.fileWrappers else {
            // A package presented as something other than a readable directory
            // (for example an unmaterialized iCloud placeholder) must fail the
            // open rather than masquerade as an empty document.
            throw TypesetPackageError.unreadableFile(fileWrapper.filename ?? fileWrapper.preferredFilename ?? "package")
        }

        let entries = try Self.flatten(wrappers: wrappers, prefix: "")
        try self.init(
            files: entries.files,
            folders: entries.folders,
            compileTargetPath: entries.state?.compileTarget,
            state: entries.state ?? DocumentPackageState()
        )
        persistedState = entries.state
        recordLoadedBaseline()
    }

    func fileWrapper() -> FileWrapper {
        fileWrapper(reusingUnchangedFilesFrom: nil)
    }

    /// Builds the package's directory wrapper. When `previous` — the wrapper
    /// the document was read from — is given, files this session never changed
    /// reuse their existing child wrapper instances instead of fresh copies of
    /// the in-memory bytes. The document system recognizes reused wrappers and
    /// leaves those files' on-disk bytes alone, so a save rewrites only what
    /// actually changed (instead of the whole package every time) and an
    /// unchanged file can never be clobbered by a stale in-memory copy.
    func fileWrapper(reusingUnchangedFilesFrom previous: FileWrapper?) -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])

        for folder in allFolderPaths {
            append(folderParts: folder.split(separator: "/").map(String.init), to: root)
        }

        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            let reusable = changedPaths.contains(file.path)
                ? nil
                : Self.existingRegularFileWrapper(at: parts, in: previous)
            append(file: file, parts: parts, reusing: reusable, to: root)
        }

        let state = FileWrapper(regularFileWithContents: Data(encodeState().utf8))
        state.preferredFilename = Self.stateFileName
        root.addFileWrapper(state)

        let gitignore = FileWrapper(regularFileWithContents: Data("\(Self.stateFileName)\n".utf8))
        gitignore.preferredFilename = Self.gitignoreFileName
        root.addFileWrapper(gitignore)

        return root
    }

    /// Finds the regular-file wrapper at `parts` inside `previous`, or `nil`
    /// when the path doesn't resolve to a reusable regular file under the
    /// expected name.
    private static func existingRegularFileWrapper(at parts: [String], in previous: FileWrapper?) -> FileWrapper? {
        guard let previous, previous.isDirectory, let leafName = parts.last else { return nil }
        var directory = previous
        for part in parts.dropLast() {
            guard let child = directory.fileWrappers?[part], child.isDirectory else { return nil }
            directory = child
        }
        guard let leaf = directory.fileWrappers?[leafName], leaf.isRegularFile,
              (leaf.preferredFilename ?? leaf.filename) == leafName else {
            return nil
        }
        return leaf
    }

    private static func flatten(wrappers: [String: FileWrapper], prefix: String) throws -> (files: [PackageFile], folders: [String], state: DocumentPackageState?) {
        try wrappers.reduce(into: (files: [PackageFile](), folders: [String](), state: Optional<DocumentPackageState>.none)) { result, entry in
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
                let flattened = try flatten(wrappers: children, prefix: path)
                result.files.append(contentsOf: flattened.files)
                result.folders.append(contentsOf: flattened.folders)
                result.state = result.state ?? flattened.state
            } else if wrapper.isRegularFile {
                // A regular file whose bytes cannot be produced (an
                // unmaterialized iCloud item, a failed lazy read) fails the
                // whole open. Substituting empty data here is how an
                // incompletely synced package ends up saved back over — and
                // erasing — the real one.
                guard let contents = wrapper.regularFileContents else {
                    throw TypesetPackageError.unreadableFile(path)
                }
                result.files.append(PackageFile(path: path, data: contents))
            }
            // Anything else (symlinks, unreadable specials) is skipped rather
            // than imported as an empty file.
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
        skipped: inout [SkippedFile],
        pending: inout [String],
        state: inout DocumentPackageState?
    ) throws {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let relativePath = relativePackagePath(for: url, rootURL: rootURL)
        let name = url.lastPathComponent

        // An iCloud placeholder stub (".name.icloud") stands in for a file
        // that has not been materialized on this device. Importing the stub
        // would corrupt the package — and the next save would propagate the
        // corruption — so start the download and leave the file out; the
        // app folds it in once it lands.
        if name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 {
            let realName = String(name.dropFirst().dropLast(".icloud".count))
            let parent = (relativePath as NSString).deletingLastPathComponent
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            pending.append(parent.isEmpty ? realName : "\(parent)/\(realName)")
            return
        }

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
                    skipped: &skipped,
                    pending: &pending,
                    state: &state
                )
            }
        } else if resourceValues.isRegularFile == true {
            switch readRegularFile(at: url) {
            case .data(let data):
                files.append(PackageFile(path: relativePath, data: data))
            case .notDownloaded:
                // Not on this device yet. Left out for now — waiting here
                // would hold the whole document open on a download — and
                // requested by the app, which folds the file in on arrival.
                pending.append(relativePath)
            case .unreadable(let reason):
                // Left out rather than failing the whole folder: the file is
                // not in the package, so nothing can write over or remove it,
                // and the rest of the document still loads.
                skipped.append(SkippedFile(path: relativePath, reason: reason))
            }
        }
    }

    /// Reads a folder file's bytes, materializing a cloud placeholder first.
    ///
    /// Items in a File Provider volume (iCloud Drive, Box, Dropbox, OneDrive…)
    /// report `.notDownloaded` until their content is on this device. A plain
    /// read of such an item does not fetch it — on third-party providers it
    /// fails outright — and `startDownloadingUbiquitousItem` only reaches
    /// iCloud. A read under `NSFileCoordinator` is what every provider honors:
    /// it asks the provider for the content and blocks until it arrives. If
    /// even that fails, the provider has a stale entry for content it can no
    /// longer produce, and the caller leaves the file out.
    ///
    /// Mapping keeps large assets backed by the file on disk instead of
    /// resident in memory; safe because writers here replace atomically.
    private enum RegularFileRead {
        case data(Data)
        case notDownloaded
        case unreadable(String)
    }

    /// Reads a folder file's bytes.
    ///
    /// Items in a File Provider volume (iCloud Drive, Box, Dropbox, OneDrive…)
    /// report `.notDownloaded` until their content is on this device; those
    /// are reported as such rather than read, so opening never blocks on a
    /// download. A file the provider reports as present that still fails a
    /// plain read (a stale entry, a transient provider hiccup) gets one read
    /// under `NSFileCoordinator`, which asks the provider for the content; if
    /// that fails too, the file is unreadable and left out.
    ///
    /// Mapping keeps large assets backed by the file on disk instead of
    /// resident in memory; safe because writers here replace atomically.
    private static func readRegularFile(at url: URL) -> RegularFileRead {
        // Resource values are cached on the URL instance, so look them up on
        // a fresh one to see the provider's current answer.
        let cloudValues = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if cloudValues?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .notDownloaded
        }
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            return .data(data)
        }

        var coordinationError: NSError?
        var outcome: RegularFileRead = .unreadable("could not be read")
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                outcome = .data(try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe]))
            } catch {
                outcome = .unreadable(error.localizedDescription)
            }
        }
        if let coordinationError {
            return .unreadable(coordinationError.localizedDescription)
        }
        return outcome
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

    private func append(file: PackageFile, parts: [String], reusing reusableWrapper: FileWrapper?, to directory: FileWrapper) {
        guard let head = parts.first else { return }

        if parts.count == 1 {
            if let reusableWrapper {
                directory.addFileWrapper(reusableWrapper)
            } else {
                let child = FileWrapper(regularFileWithContents: file.data)
                child.preferredFilename = head
                directory.addFileWrapper(child)
            }
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

        append(file: file, parts: Array(parts.dropFirst()), reusing: reusableWrapper, to: childDirectory)
    }
}

/// Fetches a cloud placeholder's content onto this device.
///
/// A plain read of an item a File Provider has not materialized does not fetch
/// it (on third-party providers it fails outright), and
/// `startDownloadingUbiquitousItem` only reaches iCloud. A read under
/// `NSFileCoordinator` is what every provider honors: it asks the provider for
/// the content and returns once it is on disk. The bytes are streamed through
/// and discarded, so a large file costs no memory.
public enum CloudFileMaterializer {
    /// Returns the file's size once its content is local, or throws with the
    /// provider's reason (a stale entry whose content is gone, no connection).
    public static func materialize(fileAt url: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var coordinationError: NSError?
                var outcome: Result<Int, Error> = .failure(CocoaError(.fileReadUnknown))
                NSFileCoordinator(filePresenter: nil).coordinate(
                    readingItemAt: url,
                    options: [],
                    error: &coordinationError
                ) { coordinatedURL in
                    outcome = Result {
                        let handle = try FileHandle(forReadingFrom: coordinatedURL)
                        defer { try? handle.close() }
                        var total = 0
                        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                            total += chunk.count
                        }
                        return total
                    }
                }
                if let coordinationError {
                    outcome = .failure(coordinationError)
                }
                continuation.resume(with: outcome)
            }
        }
    }
}

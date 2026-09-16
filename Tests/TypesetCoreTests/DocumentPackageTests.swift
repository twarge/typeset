// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

@Test func defaultPackageUsesTypesetDemoSource() throws {
    let package = try DocumentPackage()
    let source = package.text(for: "main.typ")

    #expect(source.hasPrefix("= Typeset\n\nTypst is a document creation language."))
    #expect(source.contains("#import \"@preview/fletcher:0.5.8\" as fletcher"))
    #expect(source.contains("== Quantum circuits"))
    #expect(source.contains("Typeset can save a package that contains multiple `.typ` files"))
}

@Test func emptyFilesProduceValidBlankPackage() throws {
    // New documents use `emptyFiles()` instead of the demo when the user turns
    // off sample content in Settings. The package must still be valid: a single
    // empty `main.typ` that is the compile target.
    let package = try DocumentPackage(files: DocumentPackage.emptyFiles())

    #expect(package.files.count == 1)
    #expect(package.mainTypstPath == "main.typ")
    #expect(package.text(for: "main.typ").isEmpty)
}

@Test func packageRoundTripsNestedFiles() throws {
    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/note.txt", data: Data("asset".utf8)),
    ])

    let roundTripped = try DocumentPackage(fileWrapper: package.fileWrapper())

    #expect(roundTripped.files.map(\.path) == ["assets/note.txt", "main.typ"])
    #expect(roundTripped.text(for: "main.typ") == "= Hello")
}

@Test func packagePersistsCompileTarget() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
    ])

    try package.setCompileTarget(path: "chapters/one.typ")
    let wrapper = package.fileWrapper()
    let roundTripped = try DocumentPackage(fileWrapper: wrapper)

    #expect(roundTripped.compileTargetPath == "chapters/one.typ")
    #expect(roundTripped.files.map(\.path) == ["chapters/one.typ", "main.typ"])
    // The compile target lives in the state file; the legacy standalone
    // `.typeset` metadata file is no longer written.
    #expect(wrapper.fileWrappers?[".typeset"] == nil)
    let stateText = String(data: wrapper.fileWrappers?[".typesetstate"]?.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    #expect(stateText.contains("compile_target = \"chapters/one.typ\""))
}

@Test func packageIgnoresAndDropsLegacyMetadataFile() throws {
    let root = FileWrapper(directoryWithFileWrappers: [:])
    let main = FileWrapper(regularFileWithContents: Data("= Main".utf8))
    main.preferredFilename = "main.typ"
    root.addFileWrapper(main)
    let other = FileWrapper(regularFileWithContents: Data("= Other".utf8))
    other.preferredFilename = "other.typ"
    root.addFileWrapper(other)
    let legacy = FileWrapper(regularFileWithContents: Data("other.typ\n".utf8))
    legacy.preferredFilename = ".typeset"
    root.addFileWrapper(legacy)

    let package = try DocumentPackage(fileWrapper: root)

    // The obsolete `.typeset` metadata file is never read: it neither sets
    // the compile target nor appears as a package file, and a save drops it.
    #expect(package.compileTargetPath == "main.typ")
    #expect(package.files.map(\.path) == ["main.typ", "other.typ"])
    #expect(package.fileWrapper().fileWrappers?[".typeset"] == nil)
}

@Test func packagePersistsEditorStateAsToml() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
    ])

    try package.updateEditorState(selectedFile: "chapters/one.typ", cursorLocation: 4, cursorLength: 2)
    package.updateExpandedFolders(["chapters"])
    let wrapper = package.fileWrapper()
    let stateText = try #require(wrapper.fileWrappers?[".typesetstate"]?.regularFileContents)
    let gitignoreText = try #require(wrapper.fileWrappers?[".gitignore"]?.regularFileContents)
    let roundTripped = try DocumentPackage(fileWrapper: wrapper)

    #expect(String(decoding: stateText, as: UTF8.self).contains("selected_file = \"chapters/one.typ\""))
    #expect(String(decoding: stateText, as: UTF8.self).contains("cursor_location = 4"))
    #expect(String(decoding: stateText, as: UTF8.self).contains("cursor_length = 2"))
    #expect(String(decoding: stateText, as: UTF8.self).contains("expanded_folders = [\"chapters\"]"))
    #expect(String(decoding: gitignoreText, as: UTF8.self) == ".typesetstate\n")
    #expect(roundTripped.selectedPath == "chapters/one.typ")
    #expect(roundTripped.state == DocumentPackageState(selectedFile: "chapters/one.typ", cursorLocation: 4, cursorLength: 2, expandedFolders: ["chapters"]))
    #expect(roundTripped.files.map(\.path) == ["chapters/one.typ", "main.typ"])
}

@Test func packagePersistsRestoreStateAsToml() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
    ])

    package.updateScrollFraction(0.42)
    package.updatePreviewViewport(scale: 1.75, page: 2, pointX: 36.5, pointY: 220.25)
    package.updateViewMode("preview")
    package.updateSidebarTab("outline")

    let wrapper = package.fileWrapper()
    let stateText = try #require(wrapper.fileWrappers?[".typesetstate"]?.regularFileContents)
    let toml = String(decoding: stateText, as: UTF8.self)
    let roundTripped = try DocumentPackage(fileWrapper: wrapper)

    #expect(toml.contains("scroll_fraction = 0.420000"))
    #expect(toml.contains("preview_scale = 1.750000"))
    #expect(toml.contains("preview_page = 2"))
    #expect(toml.contains("view_mode = \"preview\""))
    #expect(toml.contains("sidebar_tab = \"outline\""))
    #expect(abs(roundTripped.state.scrollFraction - 0.42) < 0.0001)
    #expect(abs(roundTripped.state.previewScale - 1.75) < 0.0001)
    #expect(roundTripped.state.previewPage == 2)
    #expect(abs(roundTripped.state.previewPointX - 36.5) < 0.001)
    #expect(abs(roundTripped.state.previewPointY - 220.25) < 0.001)
    #expect(roundTripped.state.viewMode == "preview")
    #expect(roundTripped.state.sidebarTab == "outline")
}

@Test func packageClampsAndIgnoresOutOfRangeScrollFraction() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
    ])
    package.updateScrollFraction(2.5)
    #expect(package.state.scrollFraction == 1)
    package.updateScrollFraction(-3)
    #expect(package.state.scrollFraction == 0)
}

@Test func packageLoadsEnclosingDirectoryForTypstFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "TypesetDirectoryOpen-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let openedFile = directory.appending(path: "chapter.typ")
    let mainFile = directory.appending(path: "main.typ")
    let imageFolder = directory.appending(path: "images", directoryHint: .isDirectory)
    let stateFile = directory.appending(path: ".typesetstate")
    let gitignoreFile = directory.appending(path: ".gitignore")

    try FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
    try Data("= Chapter".utf8).write(to: openedFile)
    try Data("= Main".utf8).write(to: mainFile)
    try Data([1, 2, 3]).write(to: imageFolder.appending(path: "figure.png"))
    try Data("selected_file = \"main.typ\"\ncursor_location = 7\ncursor_length = 0\n".utf8).write(to: stateFile)
    try Data(".typesetstate\n".utf8).write(to: gitignoreFile)

    let package = try DocumentPackage(directoryURL: directory, openedFileURL: openedFile)

    #expect(package.selectedPath == "chapter.typ")
    #expect(package.compileTargetPath == "chapter.typ")
    #expect(package.files.map(\.path) == ["chapter.typ", "images/figure.png", "main.typ"])
    #expect(package.allFolderPaths == ["images"])
}

@Test func packageFallsBackWhenCompileTargetIsMissing() throws {
    let package = try DocumentPackage(
        files: [
            PackageFile(path: "alpha.typ", data: Data("= Alpha".utf8)),
            PackageFile(path: "zeta.typ", data: Data("= Zeta".utf8)),
        ],
        compileTargetPath: "missing.typ"
    )

    #expect(package.compileTargetPath == "alpha.typ")
}

@Test func packageTracksCompileTargetRenameAndMove() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "draft.typ", data: Data("= Draft".utf8)),
    ])
    try package.setCompileTarget(path: "draft.typ")

    let renamed = try package.renameFile(at: "draft.typ", to: "final.typ")
    _ = try package.createFolder(named: "chapters")
    let moved = try package.moveFile(at: renamed, toFolder: "chapters")

    #expect(package.compileTargetPath == moved)
}

@Test func packageRoundTripsThroughDiskLikeDocumentGroupCreate() throws {
    // Mirrors the iOS "Create Document" flow: the new package is written to
    // disk as a `.typeset` directory, then re-read to open the editor. The
    // re-read goes through a fresh `FileWrapper(url:)` whose children load
    // `regularFileContents` lazily — which behaves differently from the
    // in-memory wrapper exercised by the other round-trip tests.
    let package = try DocumentPackage()

    let url = FileManager.default.temporaryDirectory
        .appending(path: "Untitled-\(UUID().uuidString).typeset", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: url) }

    let writeWrapper = package.fileWrapper()
    writeWrapper.preferredFilename = url.lastPathComponent
    try writeWrapper.write(to: url, options: .atomic, originalContentsURL: nil)

    let readWrapper = try FileWrapper(url: url, options: .immediate)
    let reopened = try DocumentPackage(fileWrapper: readWrapper)

    #expect(reopened.files.contains { $0.isTypstSource })
    #expect(reopened.selectedPath == package.selectedPath)
    #expect(reopened.compileTargetPath == package.compileTargetPath)
}

@Test func packageRoundTripsEmptyFolders() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
    ])

    let createdPath = try package.createFolder(named: "figures", in: "assets")
    let roundTripped = try DocumentPackage(fileWrapper: package.fileWrapper())

    #expect(createdPath == "assets/figures")
    #expect(roundTripped.allFolderPaths == ["assets", "assets/figures"])
}

@Test func packageAddsDroppedFilesWithUniqueNames() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/image.png", data: Data([1])),
    ])

    let path = try package.addFile(named: "image.png", data: Data([2]), in: "assets")

    #expect(path == "assets/image 2.png")
    #expect(package.files.map(\.path) == ["assets/image 2.png", "assets/image.png", "main.typ"])
}

@Test func packageMovesFilesIntoFolders() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "diagram.svg", data: Data("<svg/>".utf8)),
    ])
    _ = try package.createFolder(named: "figures")

    let path = try package.moveFile(at: "diagram.svg", toFolder: "figures")

    #expect(path == "figures/diagram.svg")
    #expect(package.files.map(\.path) == ["figures/diagram.svg", "main.typ"])
}

@Test func packageMovesFilesAndUpdatesReferencesInSameMutation() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("#image(\"diagram.svg\")".utf8)),
        PackageFile(path: "diagram.svg", data: Data("<svg/>".utf8)),
    ])
    _ = try package.createFolder(named: "figures")

    let path = try package.moveFile(at: "diagram.svg", toFolder: "figures", updatingReferences: true)

    #expect(path == "figures/diagram.svg")
    #expect(package.text(for: "main.typ") == "#image(\"figures/diagram.svg\")")
}

@Test func packageRenamesFiles() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/old.typ", data: Data("= Old".utf8)),
    ])
    try package.select(path: "assets/old.typ")

    let path = try package.renameFile(at: "assets/old.typ", to: "new.typ")

    #expect(path == "assets/new.typ")
    #expect(package.selectedPath == "assets/new.typ")
    #expect(package.files.map(\.path) == ["assets/new.typ", "main.typ"])
}

@Test func packageRenamesFilesAndUpdatesSiblingReferencesInSameMutation() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("#include \"chapters/old.typ\"".utf8)),
        PackageFile(path: "chapters/index.typ", data: Data("#include \"old.typ\"".utf8)),
        PackageFile(path: "chapters/old.typ", data: Data("= Old".utf8)),
    ])

    let path = try package.renameFile(at: "chapters/old.typ", to: "new.typ", updatingReferences: true)

    #expect(path == "chapters/new.typ")
    #expect(package.text(for: "main.typ") == "#include \"chapters/new.typ\"")
    #expect(package.text(for: "chapters/index.typ") == "#include \"new.typ\"")
}

@Test func packageRenamesFoldersAndDescendants() throws {
    var package = try DocumentPackage(
        files: [
            PackageFile(path: "main.typ", data: Data("= Main".utf8)),
            PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
            PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
        ],
        state: DocumentPackageState(
            selectedFile: "chapters/one.typ",
            cursorLocation: 4,
            cursorLength: 0,
            expandedFolders: ["chapters", "chapters/assets"]
        )
    )
    try package.setCompileTarget(path: "chapters/one.typ")
    try package.select(path: "chapters/one.typ", resettingEditorState: false)

    let path = try package.renameFolder(at: "chapters", to: "sections")

    #expect(path == "sections")
    #expect(package.files.map(\.path) == ["main.typ", "sections/assets/figure.png", "sections/one.typ"])
    #expect(package.allFolderPaths == ["sections", "sections/assets"])
    #expect(package.selectedPath == "sections/one.typ")
    #expect(package.compileTargetPath == "sections/one.typ")
    #expect(package.state == DocumentPackageState(
        selectedFile: "sections/one.typ",
        cursorLocation: 4,
        cursorLength: 0,
        expandedFolders: ["sections", "sections/assets"]
    ))
}

@Test func packageMovesFoldersAndDescendants() throws {
    var package = try DocumentPackage(
        files: [
            PackageFile(path: "main.typ", data: Data("= Main".utf8)),
            PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
            PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
            PackageFile(path: "sections/two.typ", data: Data("= Two".utf8)),
        ],
        state: DocumentPackageState(
            selectedFile: "chapters/one.typ",
            cursorLocation: 4,
            cursorLength: 0,
            expandedFolders: ["chapters", "chapters/assets"]
        )
    )
    try package.setCompileTarget(path: "chapters/one.typ")
    try package.select(path: "chapters/one.typ", resettingEditorState: false)

    let path = try package.moveFolder(at: "chapters", toFolder: "sections")

    #expect(path == "sections/chapters")
    #expect(package.files.map(\.path) == [
        "main.typ",
        "sections/chapters/assets/figure.png",
        "sections/chapters/one.typ",
        "sections/two.typ",
    ])
    #expect(package.allFolderPaths == ["sections", "sections/chapters", "sections/chapters/assets"])
    #expect(package.selectedPath == "sections/chapters/one.typ")
    #expect(package.compileTargetPath == "sections/chapters/one.typ")
    #expect(package.state == DocumentPackageState(
        selectedFile: "sections/chapters/one.typ",
        cursorLocation: 4,
        cursorLength: 0,
        expandedFolders: ["sections/chapters", "sections/chapters/assets"]
    ))
}

@Test func packageMovesFoldersAndUpdatesReferencesInSameMutation() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("#include \"chapters/one.typ\"\n#image(\"chapters/assets/figure.png\")".utf8)),
        PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
        PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
        PackageFile(path: "sections/two.typ", data: Data("= Two".utf8)),
    ])

    let path = try package.moveFolder(at: "chapters", toFolder: "sections", updatingReferences: true)

    #expect(path == "sections/chapters")
    #expect(package.text(for: "main.typ") == "#include \"sections/chapters/one.typ\"\n#image(\"sections/chapters/assets/figure.png\")")
}

@Test func packageRejectsMovingFolderIntoItself() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
        PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
    ])

    do {
        _ = try package.moveFolder(at: "chapters", toFolder: "chapters/assets")
        Issue.record("Expected moving a folder into itself to throw")
    } catch let error as TypesetPackageError {
        #expect(error == .cannotMoveFolderIntoItself("chapters"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func packageRejectsFolderRenameCollisions() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
        PackageFile(path: "sections/two.typ", data: Data("= Two".utf8)),
    ])

    do {
        _ = try package.renameFolder(at: "chapters", to: "sections")
        Issue.record("Expected folder rename collision to throw")
    } catch let error as TypesetPackageError {
        #expect(error == .folderAlreadyExists("sections"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func packageDeletesFilesAndUpdatesSelection() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "draft.typ", data: Data("= Draft".utf8)),
        PackageFile(path: "assets/image.png", data: Data([1])),
    ])
    try package.setCompileTarget(path: "draft.typ")
    try package.select(path: "assets/image.png")

    try package.deleteFile(at: "assets/image.png")

    #expect(package.files.map(\.path) == ["draft.typ", "main.typ"])
    #expect(package.selectedPath == "draft.typ")
    #expect(package.compileTargetPath == "draft.typ")

    try package.deleteFile(at: "draft.typ")

    #expect(package.files.map(\.path) == ["main.typ"])
    #expect(package.selectedPath == "main.typ")
    #expect(package.compileTargetPath == "main.typ")
}

@Test func packageRejectsDeletingLastTypstFile() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "assets/image.png", data: Data([1])),
    ])

    do {
        try package.deleteFile(at: "main.typ")
        Issue.record("Expected deleting the last Typst source to throw")
    } catch let error as TypesetPackageError {
        #expect(error == .noTypstFile)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(package.files.map(\.path) == ["assets/image.png", "main.typ"])
}

@Test func packageDeletesFoldersAndDescendants() throws {
    var package = try DocumentPackage(
        files: [
            PackageFile(path: "main.typ", data: Data("= Main".utf8)),
            PackageFile(path: "chapters/one.typ", data: Data("= One".utf8)),
            PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
            PackageFile(path: "notes/two.typ", data: Data("= Two".utf8)),
        ],
        state: DocumentPackageState(
            selectedFile: "chapters/one.typ",
            cursorLocation: 4,
            cursorLength: 0,
            expandedFolders: ["chapters", "chapters/assets", "notes"]
        )
    )
    try package.setCompileTarget(path: "chapters/one.typ")
    try package.select(path: "chapters/one.typ", resettingEditorState: false)

    try package.deleteFolder(at: "chapters")

    #expect(package.files.map(\.path) == ["main.typ", "notes/two.typ"])
    #expect(package.allFolderPaths == ["notes"])
    #expect(package.selectedPath == "main.typ")
    #expect(package.compileTargetPath == "main.typ")
    #expect(package.state == DocumentPackageState(
        selectedFile: "main.typ",
        cursorLocation: 0,
        cursorLength: 0,
        expandedFolders: ["notes"]
    ))
}

@Test func packageRejectsDeletingFolderWithLastTypstFile() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "chapters/main.typ", data: Data("= Main".utf8)),
        PackageFile(path: "chapters/assets/figure.png", data: Data([1])),
    ])

    do {
        try package.deleteFolder(at: "chapters")
        Issue.record("Expected deleting the last Typst source folder to throw")
    } catch let error as TypesetPackageError {
        #expect(error == .noTypstFile)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(package.files.map(\.path) == ["chapters/assets/figure.png", "chapters/main.typ"])
    #expect(package.allFolderPaths == ["chapters", "chapters/assets"])
}

@Test func packageRejectsRenameCollisions() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/one.typ", data: Data("= One".utf8)),
        PackageFile(path: "assets/two.typ", data: Data("= Two".utf8)),
    ])

    do {
        _ = try package.renameFile(at: "assets/one.typ", to: "two.typ")
        Issue.record("Expected rename collision to throw")
    } catch let error as TypesetPackageError {
        #expect(error == .fileAlreadyExists("assets/two.typ"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func previewRecordsSourceRanges() throws {
    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Title\nBody".utf8)),
    ])

    let preview = PreviewHTMLBuilder().build(package: package)

    #expect(preview.html.contains("data-source"))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: 0, end: 7)))
}

@Test func compiledPreviewWrapsSVGPages() {
    let preview = PreviewHTMLBuilder().build(svgPages: [
        "<svg viewBox=\"0 0 10 10\"><text>One</text></svg>",
        "<svg viewBox=\"0 0 10 10\"><text>Two</text></svg>",
    ])

    #expect(preview.html.contains("Page 1"))
    #expect(preview.html.contains("Page 2"))
    #expect(preview.html.contains("<svg viewBox=\"0 0 10 10\"><text>One</text></svg>"))
    #expect(preview.ranges.isEmpty)
}

@Test func compiledPreviewCanAnnotateSVGPagesForSourceSeek() {
    let preview = PreviewHTMLBuilder().build(
        svgPages: [
            """
            <svg viewBox="0 0 10 10">
              <path fill="#ffffff" d="M0 0h10v10H0z"/>
              <g><text>Title</text></g>
              <path stroke="#000000" d="M0 5h10"/>
            </svg>
            """
        ],
        sourcePath: "main.typ",
        sourceText: """
        #set text(font: "New Computer Modern")
        = Title
        #line(length: 4cm)
        """
    )

    #expect(preview.html.contains("sourceTokens"))
    #expect(preview.html.contains("data-source"))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: 39, end: 46)))
    #expect(!preview.ranges.values.contains { range in
        range.start == 0
    })
}

@Test func compiledPreviewEmbedsSourceRectsForPreciseSeek() {
    let preview = PreviewHTMLBuilder().build(
        svgPages: [
            "<svg viewBox=\"0 0 100 100\"><text>Title</text></svg>",
        ],
        sourcePath: "main.typ",
        sourceText: "= Title",
        sourceRects: [
            PreviewSourceRect(
                page: 0,
                x: 12,
                y: 20,
                width: 30,
                height: 10,
                range: SourceRange(path: "main.typ", start: 2, end: 7)
            ),
        ]
    )

    #expect(preview.sourceRects.count == 1)
    #expect(preview.html.contains("\"sourceRects\""))
    #expect(preview.html.contains("\"x\":12"))
    #expect(preview.html.contains("\"start\":2"))
}

@Test func compiledPreviewSourceSeekTreatsMultilineCommandsAsOneTarget() {
    let source = """
    = Title
    #diagram(
      edge("a", "b")
      edge("b", "c")
    )
    After
    """
    let nsSource = source as NSString
    let diagramStart = nsSource.range(of: "#diagram(").location
    let afterRange = nsSource.range(of: "After")

    let preview = PreviewHTMLBuilder().build(
        svgPages: [
            """
            <svg viewBox="0 0 10 10">
              <g><text>Title</text></g>
              <g><path d="M0 5h10"/></g>
              <g><text>After</text></g>
            </svg>
            """,
        ],
        sourcePath: "main.typ",
        sourceText: source
    )

    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: 0, end: 7)))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: diagramStart, end: afterRange.location - 1)))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: afterRange.location, end: NSMaxRange(afterRange))))
    #expect(preview.ranges.count == 3)
}

@Test func compiledPreviewSourceSeekSkipsMultilineSetupDirectivesAsOneBlock() {
    let source = """
    #set text(
      font: "New Computer Modern",
      size: 11pt,
    )
    = Title
    Body
    """
    let nsSource = source as NSString
    let titleRange = nsSource.range(of: "= Title")
    let bodyRange = nsSource.range(of: "Body")

    let preview = PreviewHTMLBuilder().build(
        svgPages: [
            """
            <svg viewBox="0 0 10 10">
              <g><text>Title</text></g>
              <g><text>Body</text></g>
            </svg>
            """,
        ],
        sourcePath: "main.typ",
        sourceText: source
    )

    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: titleRange.location, end: NSMaxRange(titleRange))))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: bodyRange.location, end: NSMaxRange(bodyRange))))
    #expect(!preview.ranges.values.contains { range in
        range.start == 0
    })
    #expect(preview.ranges.count == 2)
}

@Test func previewSourceRangesUseUTF16Offsets() throws {
    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("é\n= Title".utf8)),
    ])

    let preview = PreviewHTMLBuilder().build(package: package)

    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: 0, end: 1)))
    #expect(preview.ranges.values.contains(SourceRange(path: "main.typ", start: 2, end: 9)))
}

@Test func svgPreviewPageLoaderSortsPagesNumerically() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "TypesetSVGTest-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try "<svg>ten</svg>".write(to: directory.appending(path: "preview-page-10.svg"), atomically: true, encoding: .utf8)
    try "<svg>two</svg>".write(to: directory.appending(path: "preview-page-2.svg"), atomically: true, encoding: .utf8)
    try "<svg>one</svg>".write(to: directory.appending(path: "preview-page-1.svg"), atomically: true, encoding: .utf8)

    let pages = try SVGPreviewPageLoader().loadPages(from: directory)

    #expect(pages == ["<svg>one</svg>", "<svg>two</svg>", "<svg>ten</svg>"])
}

@Test func packageStorageProvidesTypstCompileArguments() {
    let storage = TypstPackageStorage(
        localPackagesURL: URL(fileURLWithPath: "/tmp/TypesetPackages/local"),
        packageCacheURL: URL(fileURLWithPath: "/tmp/TypesetPackages/cache")
    )

    #expect(storage.compileArguments == [
        "--package-path", "/tmp/TypesetPackages/local",
        "--package-cache-path", "/tmp/TypesetPackages/cache",
    ])
}

@Test func temporaryPackageWriterPreservesEmptyFolders() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
    ])
    let folder = try package.createFolder(named: "figures", in: "assets")

    let directory = try TemporaryPackageWriter().write(package: package)
    defer { try? FileManager.default.removeItem(at: directory) }

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
        atPath: directory.appending(path: folder).path,
        isDirectory: &isDirectory
    )
    #expect(exists)
    #expect(isDirectory.boolValue)
}

@Test func scriptsAndDataFilesAreTextEditable() throws {
    // A package holds the data a document reads and the scripts that generate
    // it; those are editable in place. Binary assets still are not.
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data()),
    ])
    for path in ["generate.py", "data.csv", "series.tsv", "config.toml", "refs.bib", "values.json"] {
        _ = try package.addFile(named: path, data: Data())
        let file = try #require(package.files.first { $0.path == path })
        #expect(file.isTextEditable, "\(path) should be editable")
        #expect(!file.isTypstSource, "\(path) is not Typst source")
    }

    _ = try package.addFile(named: "figure.png", data: Data([0x89, 0x50]))
    let image = try #require(package.files.first { $0.path == "figure.png" })
    #expect(!image.isTextEditable)
}

@Test func editingAScriptGoesThroughTheTextPath() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data()),
    ])
    _ = try package.addFile(named: "generate.py", data: Data("def rows():\n    return []\n".utf8))

    try package.updateText("def rows():\n    return [[\"1\"]]\n", for: "generate.py")
    #expect(package.text(for: "generate.py").contains("[[\"1\"]]"))

    // Binary assets still reject text edits.
    _ = try package.addFile(named: "figure.png", data: Data([0x89, 0x50]))
    #expect(throws: (any Error).self) {
        try package.updateText("nope", for: "figure.png")
    }
}

// MARK: - Data-loss safety

/// Simulates a wrapper whose bytes cannot be produced — an unmaterialized
/// iCloud item or a failed lazy read.
private final class UnreadableFileWrapper: FileWrapper {
    override var regularFileContents: Data? { nil }
}

@Test func unreadableWrapperContentFailsTheOpen() throws {
    let root = FileWrapper(directoryWithFileWrappers: [
        "main.typ": FileWrapper(regularFileWithContents: Data("= Hello".utf8)),
        "photo.png": UnreadableFileWrapper(regularFileWithContents: Data()),
    ])

    // Opening must throw rather than substitute empty content: a package that
    // opens with silently hollow files gets saved back over the real one.
    #expect(throws: TypesetPackageError.unreadableFile("photo.png")) {
        _ = try DocumentPackage(fileWrapper: root)
    }
}

@Test func nonDirectoryPackageWrapperFailsTheOpen() throws {
    let flat = FileWrapper(regularFileWithContents: Data("placeholder".utf8))
    flat.preferredFilename = "Report.typeset"

    #expect(throws: TypesetPackageError.unreadableFile("Report.typeset")) {
        _ = try DocumentPackage(fileWrapper: flat)
    }
}

@Test func loadingFromAWrapperRecordsTheBaseline() throws {
    let source = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/photo.png", data: Data(repeating: 0xAB, count: 128)),
    ])
    let loaded = try DocumentPackage(fileWrapper: source.fileWrapper())

    #expect(loaded.loadedByteCounts["main.typ"] == 7)
    #expect(loaded.loadedByteCounts["assets/photo.png"] == 128)
    #expect(loaded.changedPaths.isEmpty)
}

@Test func mutationsRecordChangedPaths() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "notes.typ", data: Data("= Notes".utf8)),
        PackageFile(path: "assets/photo.png", data: Data([0x89])),
    ])
    package.recordLoadedBaseline()

    try package.updateText("= Edited", for: "main.typ")
    #expect(package.changedPaths.contains("main.typ"))

    _ = try package.addFile(named: "extra.txt", data: Data("x".utf8))
    #expect(package.changedPaths.contains("extra.txt"))

    _ = try package.renameFile(at: "notes.typ", to: "chapter.typ")
    #expect(package.changedPaths.contains("notes.typ"))
    #expect(package.changedPaths.contains("chapter.typ"))

    _ = try package.moveFile(at: "assets/photo.png", toFolder: nil)
    #expect(package.changedPaths.contains("assets/photo.png"))
    #expect(package.changedPaths.contains("photo.png"))

    try package.deleteFile(at: "photo.png")
    #expect(package.changedPaths.contains("photo.png"))
}

@Test func folderOperationsRecordChangedPaths() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/photo.png", data: Data([0x89])),
        PackageFile(path: "assets/data.csv", data: Data("a,b".utf8)),
    ])
    package.recordLoadedBaseline()

    _ = try package.renameFolder(at: "assets", to: "resources")
    #expect(package.changedPaths.contains("assets/photo.png"))
    #expect(package.changedPaths.contains("resources/photo.png"))
    #expect(package.changedPaths.contains("assets/data.csv"))
    #expect(package.changedPaths.contains("resources/data.csv"))

    try package.deleteFolder(at: "resources")
    #expect(package.changedPaths.contains("resources/photo.png"))
    #expect(package.changedPaths.contains("resources/data.csv"))
    #expect(throws: Never.self) { try package.validateForSaving() }
}

@Test func savingRefusesToEraseUneditedContent() throws {
    let source = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/photo.png", data: Data(repeating: 0xAB, count: 128)),
    ])
    var loaded = try DocumentPackage(fileWrapper: source.fileWrapper())

    // Simulate the in-memory copy going hollow without any edit (the
    // corruption signature): direct mutation bypasses change tracking.
    let index = try #require(loaded.files.firstIndex { $0.path == "assets/photo.png" })
    loaded.files[index].data = Data()

    #expect(throws: TypesetPackageError.saveWouldEraseContent(["assets/photo.png"])) {
        try loaded.validateForSaving()
    }

    // The same applies to a file that silently vanished.
    loaded.files.remove(at: index)
    #expect(throws: TypesetPackageError.saveWouldEraseContent(["assets/photo.png"])) {
        try loaded.validateForSaving()
    }
}

@Test func savingAllowsDeliberateEditsAndDeletions() throws {
    let source = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "notes.typ", data: Data("= Notes".utf8)),
        PackageFile(path: "assets/data.csv", data: Data("a,b".utf8)),
    ])
    var loaded = try DocumentPackage(fileWrapper: source.fileWrapper())

    // Emptying a file through an edit and deleting one outright are both
    // deliberate, tracked changes — the guard must not block them.
    try loaded.updateText("", for: "notes.typ")
    try loaded.deleteFile(at: "assets/data.csv")
    #expect(throws: Never.self) { try loaded.validateForSaving() }

    // A package never loaded from disk has no baseline and no restrictions.
    var fresh = try DocumentPackage(files: [PackageFile(path: "main.typ", data: Data())])
    fresh.files[0].data = Data()
    #expect(throws: Never.self) { try fresh.validateForSaving() }
}

@Test func unchangedFilesReuseTheirOnDiskWrappers() throws {
    let source = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
        PackageFile(path: "assets/photo.png", data: Data(repeating: 0xAB, count: 128)),
    ])
    let onDisk = source.fileWrapper()
    var loaded = try DocumentPackage(fileWrapper: onDisk)

    try loaded.updateText("= Edited", for: "main.typ")
    let saved = loaded.fileWrapper(reusingUnchangedFilesFrom: onDisk)

    // The untouched asset reuses the exact wrapper instance it was read from,
    // so the document system leaves its on-disk bytes alone.
    let originalAsset = try #require(onDisk.fileWrappers?["assets"]?.fileWrappers?["photo.png"])
    let savedAsset = try #require(saved.fileWrappers?["assets"]?.fileWrappers?["photo.png"])
    #expect(savedAsset === originalAsset)

    // The edited file is written fresh from memory.
    let savedMain = try #require(saved.fileWrappers?["main.typ"])
    #expect(savedMain !== onDisk.fileWrappers?["main.typ"])
    #expect(savedMain.regularFileContents == Data("= Edited".utf8))
}

@Test func directoryLoadDefersICloudPlaceholders() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let mainURL = root.appending(path: "main.typ")
    try Data("= Hello".utf8).write(to: mainURL)
    try Data().write(to: root.appending(path: ".photo.png.icloud"))

    // The stub is neither imported as a file nor allowed to fail the open:
    // the document loads without it and reports it as pending download.
    let package = try DocumentPackage(directoryURL: root, openedFileURL: mainURL)
    #expect(package.files.map(\.path) == ["main.typ"])
    #expect(package.pendingDownloads == ["photo.png"])
    #expect(package.skippedFiles.isEmpty)
    #expect(package.onDiskRootURL == root.standardizedFileURL)
}

@Test func directoryLoadSkipsUnreadableFilesAndKeepsTheRest() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
    let unreadableURL = root.appending(path: "assets/photo.png")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    let mainURL = root.appending(path: "main.typ")
    try Data("= Hello".utf8).write(to: mainURL)
    try Data(repeating: 0xAB, count: 64).write(to: root.appending(path: "assets/ok.png"))
    try Data(repeating: 0xCD, count: 64).write(to: unreadableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)

    let package = try DocumentPackage(directoryURL: root, openedFileURL: mainURL)
    #expect(package.files.map(\.path) == ["assets/ok.png", "main.typ"])
    #expect(package.skippedFiles.map(\.path) == ["assets/photo.png"])
    // Not tracked at all, so a save can neither rewrite nor remove it.
    #expect(package.loadedByteCounts["assets/photo.png"] == nil)
    #expect(package.loadedByteCounts["assets/ok.png"] == 64)
}

@Test func bundleOnDiskCompilesInPlaceAndOverlaysSessionEdits() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bundle = root.appending(path: "Report.typeset", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle.appending(path: "Figures"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("#image(\"Figures/dot.svg\")".utf8).write(to: bundle.appending(path: "main.typ"))
    try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"><rect width=\"4\" height=\"4\"/></svg>".utf8)
        .write(to: bundle.appending(path: "Figures/dot.svg"))

    // Loaded the way the document system loads a bundle: no root of its own.
    var package = try DocumentPackage(fileWrapper: FileWrapper(url: bundle, options: .immediate))
    #expect(package.onDiskRootURL == nil)

    // With the bundle as root, the image is read from the bundle itself.
    package.onDiskRootURL = bundle
    let preview = try await TypstRenderer().previewPDF(package: package)
    #expect(preview.data.count > 100)
    #expect(!preview.diagnosticsMessage.contains("file not found"))

    // An unsaved edit is what gets compiled, not the bytes on disk.
    try package.updateText("#image(\"Figures/missing.svg\")", for: "main.typ")
    await #expect(throws: TypstRenderError.self) {
        _ = try await TypstRenderer().previewPDF(package: package)
    }
}

@Test func cloudFileMaterializerReportsLocalSizeAndMissingFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0xAB, count: 3).write(to: root.appending(path: "photo.png"))

    // A local file is already materialized; the read just reports its size.
    let size = try await CloudFileMaterializer.materialize(fileAt: root.appending(path: "photo.png"))
    #expect(size == 3)
    await #expect(throws: (any Error).self) {
        _ = try await CloudFileMaterializer.materialize(fileAt: root.appending(path: "missing.png"))
    }
}

@Test func directoryLoadRecordsTheBaseline() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root.appending(path: "assets"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let mainURL = root.appending(path: "main.typ")
    try Data("= Hello".utf8).write(to: mainURL)
    try Data(repeating: 0xAB, count: 64).write(to: root.appending(path: "assets/photo.png"))

    let package = try DocumentPackage(directoryURL: root, openedFileURL: mainURL)
    #expect(package.loadedByteCounts["main.typ"] == 7)
    #expect(package.loadedByteCounts["assets/photo.png"] == 64)
    #expect(package.changedPaths.isEmpty)
}

@Test func changeTrackingMetadataDoesNotAffectEquality() throws {
    let source = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Hello".utf8)),
    ])
    var loaded = try DocumentPackage(fileWrapper: source.fileWrapper())
    var twin = loaded

    // An edit that produces identical bytes differs only in tracking metadata;
    // the packages still compare equal (SwiftUI change detection and tests
    // care about the value, not the session history).
    try loaded.updateText("= Hello", for: "main.typ")
    #expect(loaded == twin)

    try twin.updateText("= Changed", for: "main.typ")
    #expect(loaded != twin)
}

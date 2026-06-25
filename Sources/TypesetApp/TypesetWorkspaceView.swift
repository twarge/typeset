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

func typesetLSPDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard UserDefaults.standard.bool(forKey: "developer.lspDebugLogging") else { return }
    print("[Typeset LSP UI] \(message())")
    #endif
}

func typesetDropDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Typeset Drop] \(message())")
    #endif
}

struct TypesetWorkspaceView: View {
    @Binding var document: TypesetDocument
    var fileURL: URL?

    #if os(macOS)
    @Environment(\.undoManager) private var documentUndoManager
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var selectedPath: String = ""
    @State private var selectedFolderPath: String?
    @State private var sourceText: String = ""
    @State private var previewPDF: PDFPreview?
    @State private var previewRevision = 0
    @State private var didForceInitialPreviewRecompile = false
    @State private var selectedRange: NSRange?
    @State private var selectedView: WorkspaceViewMode = .both
    @State private var exportDocument = PDFExportDocument()
    @State private var exportDefaultFilename = "Typeset Export.pdf"
    @State private var isExportPresented = false
    #if os(iOS)
    @State private var pdfShareItem: PDFShareItem?
    #endif
    @State private var isLogPresented = false
    @State private var diagnosticRunID = UUID()
    @State private var isPreviewCompiling = false
    @State private var previewNeedsRefresh = false
    @State private var previewCompileTask: Task<Void, Never>?
    // Bumped whenever a compile is superseded or stopped; an in-flight compile
    // whose token no longer matches has its result discarded.
    @State private var previewCompileToken = 0
    @State private var logEntries: [DiagnosticLogEntry] = []
    @State private var sourceDiagnostics: [String: [TypstSourceDiagnostic]] = [:]
    @State private var sourceProseRanges: [String: [TypstProseRange]] = [:]
    @State private var documentSymbols: TypstDocumentSymbols = .empty
    @State private var completionItems: [TypstCompletionItem] = []
    @State private var selectedCompletionIndex = 0
    @State private var hoverInfo: TypstHoverInfo?
    @State private var hoverDiagnosticSeverity: TypstDiagnosticSeverity?
    @State private var signatureHelp: TypstSignatureHelp?
    @State private var languageRequestID = UUID()
    @State private var languageRequestTask: Task<Void, Never>?
    @State private var languageSyncTask: Task<Void, Never>?
    @State private var pendingEditorState: PendingEditorState?
    @State private var editorStateSaveTask: Task<Void, Never>?
    // Editor scroll restore: a token + fraction handed to the editor to scroll
    // back to where the document was left; and a debounced save of live scrolls.
    @State private var scrollRestoreToken = 0
    @State private var scrollRestoreFraction = 0.0
    @State private var scrollRestoreSelection: NSRange?
    @State private var scrollRestoreReveal = false
    /// One-shot signal that the user invoked Find-in-Files (⌘⇧F): the sidebar
    /// switches to the Find tab and focuses the field, then resets it. Owned by
    /// the workspace so it survives the iOS sidebar overlay being torn down and
    /// re-created, where `.onChange` can't fire on a fresh mount.
    @State private var isFindActivationPending = false
    @State private var pendingScrollFraction: Double?
    @State private var scrollSaveTask: Task<Void, Never>?
    @State private var pendingPreviewViewport: PreviewViewport?
    @State private var previewViewportSaveTask: Task<Void, Never>?
    @State private var sourceEditorFocusRequest = 0
    @State private var commentToggleRequest = 0
    @State private var snippetInsertionToken = 0
    @State private var snippetInsertion: EditorSnippetInsertion?
    @State private var pendingFileTreeEdit: FileTreeEditingTarget?
    @State private var isImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var isFindReplacePresented = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var findIsCaseSensitive = false
    @State private var didAutoExportPDFOnDisappear = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var isFileSidebarPresented = false
    @State private var loadedTypstDirectoryFileURL: URL?
    // Directory mode (a loose `.typ` opens its enclosing folder): we mirror
    // package changes back to the real folder on disk. The snapshots track what
    // we last wrote so the diff writes only changed files and removes only files
    // we manage — never unrelated files that exist on disk.
    @State private var diskFileSnapshot: [String: Int] = [:]
    @State private var diskFolderSnapshot: Set<String> = []
    @State private var directorySyncTask: Task<Void, Never>?
    // Live folder monitoring (macOS directory mode): reflect external changes in
    // the sidebar/editor and prompt on a true conflict for the open file.
    #if os(macOS)
    @State private var directoryWatcher: DirectoryWatcher?
    #endif
    @State private var externalReconcileTask: Task<Void, Never>?
    @State private var pendingConflict: DiskConflict?
    /// Hash of the opened document's bytes the last time the editor and disk
    /// agreed (load, save echo, or a resolved conflict). The opened file is
    /// otherwise left to SwiftUI, which shows no live "changed on disk" prompt,
    /// so this lets the watcher tell a genuine external write (disk != baseline
    /// and disk != editor) from our own saves echoing back (disk == editor).
    @State private var managedFileDiskHash: Int?
    @AppStorage("workspace.splitBehavior") private var splitBehaviorRaw = SplitBehavior.automatic.rawValue
    @AppStorage("workspace.tallSplitThreshold") private var tallSplitThreshold = 1.12
    @AppStorage("appearance.theme") private var themePreferenceRaw = ThemePreference.system.rawValue
    @AppStorage("sourceEditor.imageInsertTemplate") private var imageInsertTemplate = SourceEditorDropSnippet.defaultImageTemplate
    @AppStorage("sourceEditor.figureInsertTemplate") private var figureInsertTemplate = SourceEditorDropSnippet.defaultFigureTemplate
    @AppStorage("sourceEditor.tableInsertTemplate") private var tableInsertTemplate = SourceEditorDropSnippet.defaultTableTemplate
    @AppStorage("sourceEditor.showLineNumbers") private var showLineNumbers = false
    @AppStorage("sourceEditor.spellChecking") private var spellCheckingEnabled = false
    @AppStorage("sourceEditor.spellCheckingIgnoresCommands") private var spellCheckingIgnoresCommands = true
    @AppStorage("sourceEditor.updateReferencesOnRename") private var updateReferencesOnRename = true
    @AppStorage("export.autoPDFOnClose") private var autoExportPDFOnClose = false
    @AppStorage("preview.renderWarmupDelay") private var previewRenderWarmupDelay = 0.5
    @AppStorage("developer.lspDebugLogging") private var lspDebugLoggingEnabled = false

    private let renderer = TypstRenderer()
    private let languageService = TypstLanguageServiceFactory.make()
    private let tinymistWorkspaceStore = TinymistWorkspaceStore()

    private var hasErrorLogs: Bool {
        logEntries.contains { $0.isError }
    }

    var body: some View {
        workspace
            .focusedSceneValue(\.typesetCommands, commandSet)
            #if os(macOS)
            .background(AppAppearanceConfigurator(themePreference: themePreference))
            .background(SplitViewStateConfigurator())
            #endif
            .platformPreferredColorScheme(themePreference.colorScheme)
    }

    @ViewBuilder
    private var workspace: some View {
        #if os(macOS)
        // macOS keeps the multi-column layout — a single titlebar, sidebar inline.
        NavigationSplitView(columnVisibility: navigationColumnVisibility) {
            fileSidebar(dismissAfterSelect: false)
                .navigationTitle("Package")
                .navigationSplitViewColumnWidth(min: 160, ideal: 320, max: 480)
        } detail: {
            detailContent
                .navigationTitle(selectedPath.isEmpty ? "Typeset" : selectedPath)
                .toolbar { workspaceToolbarContent }
        }
        #else
        NavigationStack {
            detailContent
                .toolbar { workspaceToolbarContent }
        }
        #endif
    }

    @ViewBuilder
    private var detailContent: some View {
        detailCore
            .platformTransparentToolbarBackground()
            .sheet(isPresented: $isSettingsPresented) {
                WorkspaceSettingsPane(
                    themePreference: themePreferenceBinding,
                    splitBehavior: splitBehaviorBinding,
                    tallSplitThreshold: $tallSplitThreshold,
                    imageInsertTemplate: $imageInsertTemplate,
                    figureInsertTemplate: $figureInsertTemplate,
                    tableInsertTemplate: $tableInsertTemplate,
                    showLineNumbers: $showLineNumbers,
                    spellCheckingEnabled: $spellCheckingEnabled,
                    spellCheckingIgnoresCommands: $spellCheckingIgnoresCommands,
                    autoExportPDFOnClose: $autoExportPDFOnClose,
                    updateReferencesOnRename: $updateReferencesOnRename,
                    previewRenderWarmupDelay: $previewRenderWarmupDelay,
                    lspDebugLoggingEnabled: $lspDebugLoggingEnabled,
                    onDismiss: { isSettingsPresented = false }
                )
            }
            #if os(iOS)
            // The right file sidebar slides over the preview / editor as
            // an overlay rather than being a SwiftUI `.inspector` column,
            // because `.inspector` resizes the leading content when it
            // appears. The overlay sits above the content panes; the
            // underlying source editor and PDF preview keep their full
            // width.
            .overlay(alignment: .trailing) {
                if isFileSidebarPresented {
                    iosFileSidebarOverlay
                }
            }
            .animation(.snappy(duration: 0.28), value: isFileSidebarPresented)
            #endif
            .fileExporter(
                isPresented: $isExportPresented,
                document: exportDocument,
                contentType: .pdf,
                defaultFilename: exportDefaultFilename
            ) { _ in }
            #if os(iOS)
            .sheet(item: $pdfShareItem) { item in
                PDFShareSheet(url: item.url)
            }
            #endif
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    importExternalFiles(urls, toFolder: folderCreationParent, copyOriginals: true)
                case .failure(let error):
                    recordLog("Import failed", message: error.localizedDescription, level: .error, present: true)
                }
            }
            .onAppear {
                loadTypstDirectoryIfNeeded()
                restoreSidebarState()
                if selectedPath.isEmpty {
                    select(document.package.selectedPath, restoringEditorState: true)
                }
                focusSourceEditor()
                syncLanguageServiceDebugLogging()
                syncLanguageServiceWorkspace()
                didForceInitialPreviewRecompile = false
                refreshPreview()
            }
            .onChange(of: fileURL) { _, _ in
                flushPendingEditorState()
                flushPendingScrollFraction()
                flushPendingPreviewViewport()
                // Flush pending edits to the OLD folder before switching, then
                // stop so a later sync can't target the NEW document's folder.
                if let oldURL = loadedTypstDirectoryFileURL {
                    syncDirectoryToDisk(root: oldURL.deletingLastPathComponent().standardizedFileURL)
                }
                directorySyncTask?.cancel()
                directorySyncTask = nil
                pendingConflict = nil
                #if os(macOS)
                stopDirectoryWatcher()
                #endif
                loadedTypstDirectoryFileURL = nil
                didAutoExportPDFOnDisappear = false
                didForceInitialPreviewRecompile = false
                loadTypstDirectoryIfNeeded()
                restoreSidebarState()
                focusSourceEditor()
                syncLanguageServiceDebugLogging()
                syncLanguageServiceWorkspace()
                refreshPreview()
            }
            .onChange(of: document.package) { _, _ in
                reconcileViewStateWithPackage()
                // In directory mode, mirror the change back to the folder on disk.
                scheduleDirectorySync()
            }
            .onChange(of: selectedView) { _, newValue in
                persistViewMode(newValue)
            }
            .onChange(of: spellCheckingIgnoresCommands) { _, _ in
                Task {
                    await refreshLanguageServiceAnnotations()
                }
            }
            .onChange(of: lspDebugLoggingEnabled) { _, _ in
                syncLanguageServiceDebugLogging()
            }
            .onDisappear {
                flushPendingEditorState()
                flushPendingScrollFraction()
                flushPendingPreviewViewport()
                // Flush any pending folder writes before the view goes away.
                syncDirectoryToDisk()
                #if os(macOS)
                stopDirectoryWatcher()
                #endif
                exportPDFOnCloseIfNeeded()
            }
            #if os(macOS)
            .background(DocumentProxyConfigurator(fileURL: fileURL, editedPath: selectedPath))
            #endif
            .alert(
                "“\(pendingConflict?.fileName ?? "")” was changed on disk",
                isPresented: Binding(
                    get: { pendingConflict != nil },
                    set: { presented in
                        // Dismissed without choosing (Escape / window close):
                        // default to keeping the user's edits rather than leaving
                        // a divergence that a later reload would silently discard.
                        if !presented, let conflict = pendingConflict {
                            resolveConflictKeepingMine(conflict)
                        }
                    }
                ),
                presenting: pendingConflict
            ) { conflict in
                Button("Keep My Version") { resolveConflictKeepingMine(conflict) }
                Button("Revert to Disk", role: .destructive) { resolveConflictRevertingToDisk(conflict) }
            } message: { _ in
                Text("This file has unsaved changes here and was also modified by another program. Keep your version, or replace it with the version on disk?")
            }
    }

    @ViewBuilder
    private var detailCore: some View {
        #if os(macOS)
        workspacePanes
        #else
        workspacePanes
        #endif
    }

    private var workspacePanes: some View {
        ZStack(alignment: .trailing) {
            contentPane

            DiagnosticLogSlideOver(
                entries: logEntries,
                isPresented: isLogPresented,
                onSelectDiagnostic: seekToDiagnostic
            )
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        #if os(macOS)
        contentView
            .ignoresSafeArea(.container, edges: .top)
        #else
        contentView
        #endif
    }

    @ToolbarContentBuilder
    private var workspaceToolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .principal) {
            iosDocumentToolbarTitle
        }
        // The view controls live alongside the document actions on the right.
        // In compact width they collapse to a single full-screen preview button.
        ToolbarItemGroup(placement: .primaryAction) {
            if isCompactWidth {
                compactPreviewToggle
            } else {
                sourceVisibilityToggle
                previewVisibilityToggle
            }
            Button {
                setFileSidebarPresented(!isFileSidebarPresented)
            } label: {
                Label("Files", systemImage: "sidebar.trailing")
            }
            exportToolbarButton
            settingsToolbarButton
            logsToolbarButton
        }
        #else
        ToolbarItemGroup(placement: .primaryAction) {
            sourceVisibilityToggle
            previewVisibilityToggle
            exportToolbarButton
            logsToolbarButton
        }
        #endif
    }

    // A pair of toolbar toggles controlling which panes are visible. They
    // drive `selectedView`; the bindings refuse to hide the last visible pane,
    // so something is always shown.
    private var sourceVisibleBinding: Binding<Bool> {
        Binding {
            selectedView != .preview
        } set: { wantVisible in
            if wantVisible {
                if selectedView == .preview { selectedView = .both }
            } else if selectedView == .both {
                // Hiding code from the split leaves the preview alone.
                selectedView = .preview
            }
        }
    }

    private var previewVisibleBinding: Binding<Bool> {
        Binding {
            selectedView != .source
        } set: { wantVisible in
            if wantVisible {
                if selectedView == .source {
                    selectedView = .both
                    refreshPreview()
                }
            } else if selectedView == .both {
                selectedView = .source
            }
        }
    }

    private var sourceVisibilityToggle: some View {
        Toggle(isOn: sourceVisibleBinding) {
            Label("Show Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("Show Code")
    }

    private var previewVisibilityToggle: some View {
        Toggle(isOn: previewVisibleBinding) {
            Label("Show Preview", systemImage: "doc.richtext")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("Show Preview")
    }

    // Compact width can't fit both panes, so a single button flips between the
    // editor and a full-screen preview.
    private var compactPreviewBinding: Binding<Bool> {
        Binding {
            selectedView == .preview
        } set: { showPreview in
            if showPreview {
                selectedView = .preview
                refreshPreview()
            } else {
                selectedView = .source
            }
        }
    }

    private var compactPreviewToggle: some View {
        Toggle(isOn: compactPreviewBinding) {
            Label("Show Preview", systemImage: "doc.richtext")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("Show Preview")
    }

    private var exportToolbarButton: some View {
        Button(action: exportPDF) {
            Label("Export PDF", systemImage: "square.and.arrow.up")
        }
        .disabled(!supportsPDFExport)
        .help("Export PDF")
    }

    private var settingsToolbarButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
    }

    private var logsToolbarButton: some View {
        Button(action: performStatusToolbarAction) {
            ToolbarStatusIcon(
                isLogPresented: isLogPresented,
                isCompiling: isPreviewCompiling,
                hasErrorLogs: hasErrorLogs
            )
        }
        .help(statusToolbarHelp)
        .accessibilityLabel(statusToolbarAccessibilityLabel)
    }

    private var statusToolbarHelp: String {
        if isLogPresented { return "Hide Logs" }
        if isPreviewCompiling { return "Stop Compiling" }
        if hasErrorLogs { return "Show Logs" }
        return "Compile Clean"
    }

    private var statusToolbarAccessibilityLabel: String {
        statusToolbarHelp
    }

    private func performStatusToolbarAction() {
        if isLogPresented {
            dismissLogs()
        } else if isPreviewCompiling {
            // Compiling state shows the stop icon — tapping cancels the compile.
            stopPreviewCompile()
        } else if hasErrorLogs {
            presentLogs()
        } else {
            // Clean state shows the run icon — tapping recompiles the preview.
            refreshPreview()
        }
    }

    private var documentToolbarFilename: String {
        guard let fileURL else { return "Typeset" }
        if fileURL.pathExtension.lowercased() == "typeset" {
            return fileURL.deletingPathExtension().lastPathComponent
        }
        return fileURL.lastPathComponent
    }

    private var documentEditedTitle: String {
        if selectedPath.isEmpty {
            documentToolbarFilename
        } else {
            "\(documentToolbarFilename) - \(selectedPath)"
        }
    }

    #if os(iOS)
    private var iosDocumentToolbarTitle: some View {
        HStack(spacing: 6) {
            Text(documentToolbarFilename)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if !selectedPath.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                Text(selectedPath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toolbarAccessibilityTitle)
    }

    private var toolbarAccessibilityTitle: String {
        documentEditedTitle
    }
    #endif

    private func fileSidebar(dismissAfterSelect: Bool) -> FileSidebar {
        FileSidebar(
            files: document.package.files,
            folders: document.package.allFolderPaths,
            selectedPath: selectedPath,
            selectedFolderPath: selectedFolderPath,
            packageFilePaths: Set(document.package.files.map(\.path)),
            packageFolderPaths: Set(document.package.allFolderPaths),
            compileTargetPath: document.package.compileTargetPath,
            canSetCompileTarget: canSetCompileTarget,
            expandedFolders: Set(document.package.state.expandedFolders),
            documentSymbols: documentSymbols,
            restoredSidebarTabRawValue: document.package.state.sidebarTab,
            findActivation: $isFindActivationPending,
            pendingEdit: $pendingFileTreeEdit,
            onSidebarTabChange: persistSidebarTab,
            onSelectSymbolRange: selectSymbolRange,
            onSearchSelectMatch: { jumpToSearchMatch(path: $0, range: $1) },
            onSearchReplaceMatch: { replaceSearchMatch(path: $0, range: $1, replacement: $2, query: $3, isCaseSensitive: $4) },
            onSearchReplaceAll: { replaceAllSearchMatches(query: $0, replacement: $1, isCaseSensitive: $2) },
            onNewFile: prepareNewFile,
            onNewFolder: prepareNewFolder,
            onImportFromPicker: { isImporterPresented = true },
            onSelectFile: { path in
                select(path)
                if dismissAfterSelect {
                    isFileSidebarPresented = false
                }
            },
            onSelectFolder: { selectedFolderPath = $0 },
            onExpandedFoldersChange: updateExpandedFolders,
            onMoveFile: moveFile,
            onMoveFolder: moveFolder,
            onImportFiles: importExternalFiles,
            onImportPhotos: importPhotos,
            onRenameFile: renameFile,
            onRenameFolder: renameFolder,
            onDeleteFile: deleteFile,
            onDuplicateFile: duplicateFile,
            onDeleteFolder: deleteFolder,
            onSetCompileTarget: setCompileTarget,
            onRunPythonScript: runPythonScriptInTerminal,
            onError: { title, message in
                recordLog(title, message: message, level: .error, present: true)
            }
        )
    }

    private var commandSet: TypesetCommandSet {
        TypesetCommandSet(
            showSource: { selectedView = .source },
            showSourceAndPreview: {
                selectedView = .both
                refreshPreview()
            },
            showPreview: {
                selectedView = .preview
                refreshPreview()
            },
            exportPDF: exportPDF,
            exportPDFToDefaultLocation: exportPDFToDefaultLocation,
            canExportPDFToDefaultLocation: canExportPDFToDefaultLocation,
            newFolder: prepareNewFolder,
            toggleLogs: {
                withAnimation(.snappy(duration: 0.28)) {
                    isLogPresented.toggle()
                }
            },
            requestCompletion: { requestLanguageIntelligence(forceCompletion: true) },
            showFindReplace: showFindReplace,
            showFindInFiles: showFindInFiles,
            findNext: { selectFindMatch(direction: .next) },
            findPrevious: { selectFindMatch(direction: .previous) },
            replaceCurrentMatch: replaceCurrentFindMatch,
            toggleParagraphComment: toggleParagraphComment,
            insertFigure: insertFigure,
            insertTable: insertTable,
            showLineNumbers: showLineNumbers,
            setShowLineNumbers: { showLineNumbers = $0 },
            showSettings: { isSettingsPresented = true }
        )
    }

    #if os(macOS)
    private var navigationColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding {
            columnVisibility
        } set: { visibility in
            columnVisibility = visibility
            if let isVisible = sidebarVisibilityState(for: visibility) {
                updateSidebarVisibility(isVisible)
            }
        }
    }

    private func sidebarVisibilityState(for visibility: NavigationSplitViewVisibility) -> Bool? {
        switch visibility {
        case .detailOnly:
            return false
        case .all, .doubleColumn:
            return true
        case .automatic:
            return nil
        default:
            return nil
        }
    }
    #endif

    #if os(iOS)
    private var fileSidebarPresentationBinding: Binding<Bool> {
        Binding {
            isFileSidebarPresented
        } set: { isPresented in
            setFileSidebarPresented(isPresented)
        }
    }

    /// Slides in from the trailing edge and floats above the content. The
    /// underlying source editor and preview are not resized — the panel
    /// just covers the right strip while it's visible.
    @ViewBuilder
    private var iosFileSidebarOverlay: some View {
        HStack(spacing: 0) {
            Divider()
            fileSidebar(dismissAfterSelect: false)
                .frame(width: 320)
        }
        .background(.thinMaterial)
        .transition(.move(edge: .trailing))
    }
    #endif

    @ViewBuilder
    private var contentView: some View {
        switch resolvedView {
        case .source:
            sourcePane
        case .preview:
            preview
        case .both:
            adaptiveSplitView
        }
    }

    /// In compact width (iPhone, narrow multitasking windows) there isn't room
    /// for a side-by-side split, so the "both" mode collapses to the editor.
    /// The preview is reached full-screen via the single preview toolbar button.
    private var resolvedView: WorkspaceViewMode {
        if isCompactWidth, selectedView == .both {
            return .source
        }
        return selectedView
    }

    private var isCompactWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    private func dismissLogs() {
        withAnimation(.snappy(duration: 0.28)) {
            isLogPresented = false
        }
    }

    private func presentLogs() {
        withAnimation(.snappy(duration: 0.28)) {
            isLogPresented = true
        }
    }

    private var adaptiveSplitView: some View {
        GeometryReader { proxy in
            let orientation = splitOrientation(for: proxy.size)

            Group {
                switch orientation {
                case .horizontal:
                    horizontalSplitView
                case .vertical:
                    verticalSplitView
                }
            }
            .animation(.snappy(duration: 0.24), value: orientation)
        }
    }

    @ViewBuilder
    private var horizontalSplitView: some View {
        #if os(macOS)
        HSplitView {
            sourcePane
                .frame(minWidth: 280, idealWidth: 460, maxWidth: .infinity)
            preview
                .frame(minWidth: 320)
        }
        #else
        HStack(spacing: 0) {
            sourcePane
            Divider()
            preview
        }
        #endif
    }

    @ViewBuilder
    private var verticalSplitView: some View {
        #if os(macOS)
        VSplitView {
            sourcePane
                .frame(minHeight: 220, idealHeight: 360, maxHeight: .infinity)
            preview
                .frame(minHeight: 240)
        }
        #else
        VStack(spacing: 0) {
            sourcePane
            Divider()
            preview
        }
        #endif
    }

    @ViewBuilder
    private var sourcePane: some View {
        StableSourcePane {
            ZStack(alignment: .topTrailing) {
                selectedFileView

                if isFindReplacePresented, selectedFile?.isTextEditable == true {
                    FindReplacePanel(
                        findText: $findText,
                        replaceText: $replaceText,
                        isCaseSensitive: $findIsCaseSensitive,
                        currentIndex: currentFindMatchDisplayIndex,
                        matchCount: findMatchRanges.count,
                        onFindChanged: selectFirstFindMatch,
                        onPrevious: { selectFindMatch(direction: .previous) },
                        onNext: { selectFindMatch(direction: .next) },
                        onReplace: replaceCurrentFindMatch,
                        onReplaceAll: replaceAllFindMatches,
                        onClose: { isFindReplacePresented = false }
                    )
                    .padding(.top, 58)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .animation(.snappy(duration: 0.18), value: isFindReplacePresented)
    }

    @ViewBuilder
    private var selectedFileView: some View {
        if let selectedFile {
            if selectedFile.isTextEditable {
                SourceEditor(
                    text: $sourceText,
                    selectedRange: $selectedRange,
                    isEditable: true,
                    focusRequest: sourceEditorFocusRequest,
                    commentToggleRequest: commentToggleRequest,
                    snippetInsertion: snippetInsertion,
                    insertableImagePaths: insertableImagePaths,
                    insertableTypstPaths: insertableTypstPaths,
                    imageInsertTemplate: imageInsertTemplate,
                    onImportExternalFile: importExternalFileForSourceDrop,
                    onImportPastedImage: importPastedImageForSourcePaste,
                    diagnostics: sourceDiagnostics[selectedPath] ?? [],
                    proseRanges: sourceProseRanges[selectedPath] ?? [],
                    completions: completionItems,
                    hoverInfo: hoverInfo,
                    hoverDiagnosticSeverity: hoverDiagnosticSeverity,
                    signatureHelp: signatureHelp,
                    selectedCompletionIndex: selectedCompletionIndex,
                    showLineNumbers: showLineNumbers,
                    spellCheckingEnabled: spellCheckingEnabled,
                    onTextChange: { text, range in
                        updateSource(text, selectionRange: range)
                    },
                    onSelectionChange: updateEditorSelection,
                    onCompletionSelected: insertCompletion,
                    onCompletionMove: moveCompletionSelection,
                    onCompletionAccept: acceptSelectedCompletion,
                    onCompletionDismiss: clearCompletions,
                    onScrollFractionChange: handleEditorScrollFraction,
                    scrollRestore: SourceEditorScrollRestore(
                        token: scrollRestoreToken,
                        fraction: scrollRestoreFraction,
                        selection: scrollRestoreSelection,
                        revealSelection: scrollRestoreReveal
                    )
                )
                .id(selectedPath)
            } else {
                PackageAssetPreview(file: selectedFile)
            }
        } else {
            ContentUnavailableView("No File Selected", systemImage: "doc")
        }
    }

    private var preview: some View {
        PDFPreviewView(
            preview: previewPDF,
            revision: previewRevision,
            renderWarmupDelay: previewRenderWarmupDelay,
            restoredViewport: restoredPreviewViewport,
            onViewportChange: handlePreviewViewportChange
        ) { range in
            seek(to: range)
        }
        .ignoresSafeArea(.container, edges: .vertical)
    }

    private var selectedFile: PackageFile? {
        document.package.selectedFile
    }

    private var insertableImagePaths: Set<String> {
        Set(document.package.files.compactMap { file in
            Self.isImageFile(path: file.path) ? file.path : nil
        })
    }

    private var insertableTypstPaths: Set<String> {
        Set(document.package.files.compactMap { file in
            file.isTypstSource ? file.path : nil
        })
    }

    private var splitBehavior: SplitBehavior {
        SplitBehavior(rawValue: splitBehaviorRaw) ?? .automatic
    }

    private var themePreference: ThemePreference {
        ThemePreference(rawValue: themePreferenceRaw) ?? .system
    }

    private var canSetCompileTarget: Bool {
        fileURL?.pathExtension.lowercased() != "typ"
    }

    private var themePreferenceBinding: Binding<ThemePreference> {
        Binding {
            themePreference
        } set: { preference in
            themePreferenceRaw = preference.rawValue
        }
    }

    private var splitBehaviorBinding: Binding<SplitBehavior> {
        Binding {
            splitBehavior
        } set: { behavior in
            splitBehaviorRaw = behavior.rawValue
        }
    }

    private func splitOrientation(for size: CGSize) -> SplitOrientation {
        #if os(iOS)
        // iOS always shows code and preview side by side — never stacked.
        return .horizontal
        #else
        switch splitBehavior {
        case .automatic:
            guard size.width > 0 else { return .horizontal }
            return (size.height / size.width) >= tallSplitThreshold ? .vertical : .horizontal
        case .sideBySide:
            return .horizontal
        case .stacked:
            return .vertical
        }
        #endif
    }

    private func loadTypstDirectoryIfNeeded() {
        guard let fileURL,
              fileURL.pathExtension.lowercased() == "typ",
              loadedTypstDirectoryFileURL != fileURL else {
            return
        }

        #if os(macOS)
        // The sandbox grant for a bare .typ document covers only the file
        // itself; reading and editing its siblings needs a folder grant.
        let directoryURL = fileURL.deletingLastPathComponent()
        guard FolderAccessStore.hasAccess(to: directoryURL, requiresWrite: true) else {
            // The open panel is modal; run it outside the view-update cycle.
            Task { @MainActor in
                guard FolderAccessStore.ensureAccess(
                    to: directoryURL,
                    requiresWrite: true,
                    message: "Typeset edits and previews every file in the folder that contains “\(fileURL.lastPathComponent)”. Grant access to “\(directoryURL.lastPathComponent)” to open it."
                ) else {
                    recordLog(
                        "Folder access needed",
                        message: "Typeset can't open \(directoryURL.path) without permission. Reopen the file to grant access to its folder.",
                        level: .error,
                        present: true
                    )
                    return
                }
                loadTypstDirectory(openedFileURL: fileURL)
                // The first compile ran before this grant, on the lone document
                // file, so it couldn't read the document's imports or assets.
                // Recompile now that the whole folder is accessible.
                refreshPreview()
            }
            return
        }
        #endif

        loadTypstDirectory(openedFileURL: fileURL)
    }

    private func loadTypstDirectory(openedFileURL fileURL: URL) {
        guard loadedTypstDirectoryFileURL != fileURL else { return }

        do {
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            document.package = try DocumentPackage(
                directoryURL: fileURL.deletingLastPathComponent(),
                openedFileURL: fileURL,
                openedFileIsAuthoritative: true
            )
            loadedTypstDirectoryFileURL = fileURL
            // The freshly loaded package already matches the folder on disk.
            resetDiskSnapshotFromPackage()
            #if os(macOS)
            startDirectoryWatcher()
            #endif
            selectedPath = ""
            selectedFolderPath = nil
            select(document.package.selectedPath, restoringEditorState: true)
        } catch {
            recordLog("Directory load failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func select(_ path: String, restoringEditorState: Bool = false, revealing: NSRange? = nil) {
        cancelPendingEditorStateSave()
        do {
            try withoutDocumentUndo {
                try document.package.select(path: path, resettingEditorState: !restoringEditorState)
            }
            selectedPath = path
            selectedFolderPath = nil
            sourceText = document.package.text(for: path)
            languageRequestTask?.cancel()
            languageSyncTask?.cancel()
            let ignoreCommands = spellCheckingIgnoresCommands
            Task {
                let prose = await languageService.proseRanges(
                    path: path,
                    ignoringCommandsAndArguments: ignoreCommands
                )
                await MainActor.run {
                    sourceProseRanges[path] = prose
                }
            }
            // Restore only from state that was actually loaded from a
            // persisted state file; live `state` may already carry cursor
            // positions from this session's editor activity. Packages without
            // a state file always open at the top.
            let persistedState = document.package.persistedState
            let restoredRange = NSRange(
                location: persistedState?.cursorLocation ?? 0,
                length: persistedState?.cursorLength ?? 0
            )
            // Clear the live navigation selection; the restored caret (if any)
            // is applied through the post-layout restore path below so it lands
            // reliably even on a just-opened document.
            selectedRange = nil
            let shouldRestoreEditorState = restoringEditorState && persistedState?.selectedFile == path
            let restoredSelection: NSRange? = shouldRestoreEditorState
                ? clampedRange(restoredRange, in: sourceText)
                : nil
            // When `revealing` is set (jump to a Find match), scroll that
            // range into view. Reopening is different: restore the persisted
            // caret without revealing it, then restore the saved viewport
            // fraction independently so a caret near the end does not pull the
            // editor to the bottom.
            if let revealing {
                requestEditorReveal(clampedRange(revealing, in: sourceText))
            } else if shouldRestoreEditorState, let persistedState {
                requestEditorScrollRestore(
                    persistedState.scrollFraction,
                    selection: restoredSelection
                )
            } else {
                requestEditorScrollRestore(0, selection: NSRange(location: 0, length: 0))
            }
            clearCompletions()
            hoverInfo = nil
            hoverDiagnosticSeverity = nil
            signatureHelp = nil
        } catch {
            recordLog("Selection failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func focusSourceEditor() {
        guard selectedFile?.isTextEditable == true else { return }
        sourceEditorFocusRequest += 1
    }

    private func toggleParagraphComment() {
        guard selectedFile?.isTextEditable == true, selectedView != .preview else { return }
        commentToggleRequest += 1
    }

    private func updateEditorSelection(_ range: NSRange) {
        let path = selectedPath
        DispatchQueue.main.async {
            guard selectedPath == path else { return }
            applyEditorSelection(range, for: path, allowAutomaticCompletion: false)
        }
    }

    private func applyEditorSelection(
        _ range: NSRange,
        for path: String,
        allowAutomaticCompletion: Bool,
        requestIntelligence: Bool = true,
        clearBoundSelection: Bool = true
    ) {
        guard selectedPath == path else { return }
        guard selectedFile?.isTextEditable == true else { return }
        let range = clampedRange(range, in: sourceText)
        if clearBoundSelection {
            selectedRange = nil
        }
        let nextState = PendingEditorState(
            selectedFile: path,
            cursorLocation: range.location,
            cursorLength: range.length
        )

        if documentEditorStateMatches(nextState) {
            cancelPendingEditorStateSave()
            if requestIntelligence {
                requestLanguageIntelligence(
                    allowAutomaticCompletion: allowAutomaticCompletion,
                    selectionRange: range
                )
            }
            return
        }
        guard pendingEditorState != nextState else { return }

        pendingEditorState = nextState
        scheduleEditorStateSave()
        if requestIntelligence {
            requestLanguageIntelligence(
                allowAutomaticCompletion: allowAutomaticCompletion,
                selectionRange: range
            )
        }
    }

    /// Asks the editor to restore its scroll to `fraction` (0...1) and, when
    /// given, its caret `selection` — once, after the next layout. Bumping the
    /// token makes the request fire even if the values are unchanged. Routing the
    /// caret through this post-layout path (rather than the live `selectedRange`
    /// binding) makes restore reliable on a freshly opened document.
    private func requestEditorScrollRestore(_ fraction: Double, selection: NSRange? = nil) {
        scrollRestoreFraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        scrollRestoreSelection = selection
        scrollRestoreReveal = false
        scrollRestoreToken += 1
    }

    /// Asks the editor to select `range` and scroll it into view (centered),
    /// rather than restoring a saved fraction. Carried on the same token as a
    /// normal restore so a cross-file "jump to match" can never race the
    /// destination file's restored scroll position.
    private func requestEditorReveal(_ range: NSRange) {
        scrollRestoreSelection = range
        scrollRestoreReveal = true
        scrollRestoreToken += 1
    }

    private func handleEditorScrollFraction(_ fraction: Double) {
        pendingScrollFraction = fraction
        scrollSaveTask?.cancel()
        scrollSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushPendingScrollFraction()
        }
    }

    private func flushPendingScrollFraction() {
        scrollSaveTask?.cancel()
        scrollSaveTask = nil
        guard let fraction = pendingScrollFraction else { return }
        pendingScrollFraction = nil
        guard abs(document.package.state.scrollFraction - fraction) > 0.0005 else { return }
        withoutDocumentUndo {
            document.package.updateScrollFraction(fraction)
        }
    }

    private var restoredPreviewViewport: PreviewViewport? {
        // Restore only from state loaded from disk; live state starts taking
        // viewport updates from the preview itself well before the first
        // compile finishes, which would clobber the saved spot.
        guard let state = document.package.persistedState else { return nil }
        let viewport = PreviewViewport(
            scale: state.previewScale,
            page: state.previewPage,
            x: state.previewPointX,
            y: state.previewPointY
        )
        return viewport.isMeaningful ? viewport : nil
    }

    private func handlePreviewViewportChange(_ viewport: PreviewViewport) {
        pendingPreviewViewport = viewport
        previewViewportSaveTask?.cancel()
        previewViewportSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushPendingPreviewViewport()
        }
    }

    private func flushPendingPreviewViewport() {
        previewViewportSaveTask?.cancel()
        previewViewportSaveTask = nil
        guard let viewport = pendingPreviewViewport else { return }
        pendingPreviewViewport = nil
        let state = document.package.state
        let unchanged = abs(state.previewScale - viewport.scale) < 0.0005
            && state.previewPage == viewport.page
            && abs(state.previewPointX - viewport.x) < 0.5
            && abs(state.previewPointY - viewport.y) < 0.5
        guard !unchanged else { return }
        withoutDocumentUndo {
            document.package.updatePreviewViewport(
                scale: viewport.scale,
                page: viewport.page,
                pointX: viewport.x,
                pointY: viewport.y
            )
        }
    }

    private func scheduleEditorStateSave() {
        editorStateSaveTask?.cancel()
        editorStateSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            flushPendingEditorState(cancelScheduledTask: false)
        }
    }

    private func flushPendingEditorState(cancelScheduledTask: Bool = true) {
        if cancelScheduledTask {
            editorStateSaveTask?.cancel()
        }
        editorStateSaveTask = nil

        guard let pendingEditorState else { return }
        self.pendingEditorState = nil
        guard !documentEditorStateMatches(pendingEditorState) else { return }

        do {
            try withoutDocumentUndo {
                try document.package.updateEditorState(
                    selectedFile: pendingEditorState.selectedFile,
                    cursorLocation: pendingEditorState.cursorLocation,
                    cursorLength: pendingEditorState.cursorLength
                )
            }
        } catch {
            recordLog("Editor state update failed", message: error.localizedDescription, level: .warning)
        }
    }

    private func cancelPendingEditorStateSave() {
        editorStateSaveTask?.cancel()
        editorStateSaveTask = nil
        pendingEditorState = nil
    }

    private func documentEditorStateMatches(_ editorState: PendingEditorState) -> Bool {
        document.package.state.selectedFile == editorState.selectedFile &&
            document.package.state.cursorLocation == editorState.cursorLocation &&
            document.package.state.cursorLength == editorState.cursorLength
    }

    private func updateExpandedFolders(_ expandedFolders: Set<String>) {
        withoutDocumentUndo {
            document.package.updateExpandedFolders(Array(expandedFolders))
        }
    }

    private func restoreSidebarState() {
        let isVisible = document.package.state.isSidebarVisible
        #if os(macOS)
        columnVisibility = isVisible ? .all : .detailOnly
        #else
        isFileSidebarPresented = isVisible
        #endif

        // Restore which panes were visible. An empty/unknown stored value leaves
        // the current default (`.both`) in place.
        if let restoredMode = WorkspaceViewMode(rawValue: document.package.state.viewMode) {
            selectedView = restoredMode
        }
    }

    private func persistViewMode(_ mode: WorkspaceViewMode) {
        guard document.package.state.viewMode != mode.rawValue else { return }
        withoutDocumentUndo {
            document.package.updateViewMode(mode.rawValue)
        }
    }

    private func persistSidebarTab(_ rawValue: String) {
        guard document.package.state.sidebarTab != rawValue else { return }
        withoutDocumentUndo {
            document.package.updateSidebarTab(rawValue)
        }
    }

    private func updateSidebarVisibility(_ isVisible: Bool) {
        guard document.package.state.isSidebarVisible != isVisible else { return }
        withoutDocumentUndo {
            document.package.updateSidebarVisibility(isVisible)
        }
    }

    private func setFileSidebarPresented(_ isPresented: Bool) {
        #if os(macOS)
        columnVisibility = isPresented ? .all : .detailOnly
        #else
        isFileSidebarPresented = isPresented
        #endif
        updateSidebarVisibility(isPresented)
    }

    private func updateSource(_ text: String, selectionRange: NSRange? = nil) {
        guard selectedFile?.isTextEditable == true else { return }
        let path = selectedPath
        if let selectionRange {
            applyEditorSelection(
                selectionRange,
                for: path,
                allowAutomaticCompletion: true,
                requestIntelligence: false,
                clearBoundSelection: false
            )
        }
        do {
            try withoutDocumentUndo {
                try document.package.updateSelectedText(text)
            }
            syncLanguageServiceFile(path: path, text: text, selectionRange: selectionRange)
            refreshPreview()
        } catch {
            recordLog("Source update failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func withoutDocumentUndo<T>(_ updates: () throws -> T) rethrows -> T {
        #if os(macOS)
        let shouldReenableUndo = documentUndoManager?.isUndoRegistrationEnabled == true
        if shouldReenableUndo {
            documentUndoManager?.disableUndoRegistration()
        }
        defer {
            if shouldReenableUndo {
                documentUndoManager?.enableUndoRegistration()
            }
        }
        #endif

        return try updates()
    }

    private func refreshPreview() {
        previewNeedsRefresh = true
        startPreviewCompileIfNeeded()
    }

    private func startPreviewCompileIfNeeded() {
        guard !isPreviewCompiling, previewNeedsRefresh else { return }
        previewNeedsRefresh = false
        isPreviewCompiling = true

        previewCompileToken += 1
        let token = previewCompileToken
        let runID = beginDiagnosticRun()
        let package = document.package
        let renderer = self.renderer
        previewCompileTask = Task {
            do {
                let preview = try await renderer.previewPDF(package: package)
                await MainActor.run {
                    // Ignore the result if this compile was stopped or
                    // superseded while the renderer was still running.
                    guard token == previewCompileToken else { return }
                    finishPreviewCompile(runID: runID, result: .success(preview))
                }
            } catch {
                await MainActor.run {
                    guard token == previewCompileToken else { return }
                    finishPreviewCompile(runID: runID, result: .failure(error))
                }
            }
        }
    }

    /// Stops the in-flight preview compile. The underlying compile may finish in
    /// the background, but its result is discarded (via the token bump) and the
    /// UI returns to the idle "run" state immediately.
    private func stopPreviewCompile() {
        guard isPreviewCompiling else { return }
        previewCompileToken += 1
        previewCompileTask?.cancel()
        previewCompileTask = nil
        previewNeedsRefresh = false
        isPreviewCompiling = false
    }

    private func finishPreviewCompile(runID: UUID, result: Result<PDFPreview, Error>) {
        switch result {
        case .success(let preview):
            previewRevision += 1
            previewPDF = preview
            logEntries.removeAll()
            sourceDiagnostics.removeAll()
            if !didForceInitialPreviewRecompile {
                didForceInitialPreviewRecompile = true
                previewNeedsRefresh = true
            }
        case .failure(let error):
            let parsedDiagnostics = compilerDiagnostics(from: error.localizedDescription)
            if !parsedDiagnostics.isEmpty {
                mergeDiagnostics(parsedDiagnostics)
                recordDiagnostics(parsedDiagnostics, runID: runID, present: true)
            } else {
                recordLog(
                    "Preview compilation failed",
                    message: error.localizedDescription,
                    level: .error,
                    runID: runID,
                    present: true
                )
            }
        }

        previewCompileTask = nil
        isPreviewCompiling = false
        startPreviewCompileIfNeeded()
    }

    private func syncLanguageServiceWorkspace() {
        languageSyncTask?.cancel()
        let documentID = languageServiceDocumentID
        let package = document.package
        Task {
            do {
                let root = try await tinymistWorkspaceStore.materialize(package: package, documentID: documentID)
                let packageStorage = try TypstPackageStorage.appSupportStorage()
                try packageStorage.createDirectories()
                await languageService.setWorkspace(rootURL: root, compileTarget: package.compileTargetPath)
                await languageService.setPackageStorage(
                    localPackagesURL: packageStorage.localPackagesURL,
                    packageCacheURL: packageStorage.packageCacheURL
                )
                await languageService.setPackageFilePaths(package.files.map(\.path))
                for file in package.files where file.isTextEditable {
                    await languageService.updateFile(path: file.path, text: String(decoding: file.data, as: UTF8.self))
                }
                await refreshLanguageServiceAnnotations()
            } catch {
                await MainActor.run {
                    recordLog("Language service failed", message: error.localizedDescription, level: .warning)
                }
            }
        }
    }

    private func syncLanguageServiceDebugLogging() {
        let isEnabled = lspDebugLoggingEnabled
        Task {
            await languageService.setDebugLoggingEnabled(isEnabled)
        }
    }

    private func syncLanguageServiceFile(path: String, text: String, selectionRange: NSRange? = nil) {
        let documentID = languageServiceDocumentID
        languageSyncTask?.cancel()
        languageSyncTask = Task {
            _ = try? await tinymistWorkspaceStore.updateFile(
                documentID: documentID,
                path: path,
                data: Data(text.utf8)
            )
            guard !Task.isCancelled else { return }
            await languageService.updateFile(path: path, text: text)
            guard !Task.isCancelled else { return }
            await requestLanguageIntelligenceForCurrentSelection(
                forceCompletion: false,
                allowAutomaticCompletion: true,
                selectionRange: selectionRange
            )
            guard !Task.isCancelled else { return }
            await refreshLanguageServiceAnnotations()
        }
    }

    private func refreshLanguageServiceAnnotations() async {
        let diagnostics = await languageService.diagnostics()
        let selectedProse = await languageService.proseRanges(
            path: selectedPath,
            ignoringCommandsAndArguments: spellCheckingIgnoresCommands
        )
        let symbols = await languageService.documentSymbols(path: selectedPath)
        await MainActor.run {
            mergeDiagnostics(diagnostics)
            sourceProseRanges[selectedPath] = selectedProse
            documentSymbols = symbols
        }
    }

    /// Jump the editor to a source range chosen from the outline or figure list.
    private func selectSymbolRange(_ range: NSRange) {
        if selectedView == .preview {
            selectedView = isCompactWidth ? .source : .both
        }
        selectedRange = clampedRange(range, in: sourceText)
        focusSourceEditor()
        #if os(iOS)
        setFileSidebarPresented(false)
        #endif
    }

    /// Opens `path` (if not already open) and scrolls `range` into view,
    /// centered — used by the Find sidebar to jump to a match in any file.
    private func jumpToSearchMatch(path: String, range: NSRange) {
        if selectedView == .preview {
            selectedView = isCompactWidth ? .source : .both
        }
        if selectedPath != path {
            select(path, revealing: range)
        } else {
            requestEditorReveal(clampedRange(range, in: sourceText))
        }
        focusSourceEditor()
        #if os(iOS)
        setFileSidebarPresented(false)
        #endif
    }

    /// Shows the sidebar and switches it to the Find tab, focusing the field.
    private func showFindInFiles() {
        setFileSidebarPresented(true)
        isFindActivationPending = true
    }

    /// Replaces the single occurrence at `range` in `path` with `replacement`.
    /// Verifies the range still matches before editing so a stale result (the
    /// file changed since the search ran) can't corrupt unrelated text.
    private func replaceSearchMatch(path: String, range: NSRange, replacement: String, query: String, isCaseSensitive: Bool) {
        guard document.package.files.contains(where: { $0.path == path && $0.isTextEditable }) else { return }
        let text = document.package.text(for: path)
        let nsText = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= nsText.length else { return }
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        guard nsText.substring(with: range).compare(query, options: options) == .orderedSame else { return }
        let newText = nsText.replacingCharacters(in: range, with: replacement)
        applyReplacedText(newText, for: path)
    }

    /// Replaces every occurrence of `query` across all text files.
    private func replaceAllSearchMatches(query: String, replacement: String, isCaseSensitive: Bool) {
        guard !query.isEmpty else { return }
        let targets = document.package.files.filter { $0.isTextEditable }.map(\.path)
        for path in targets {
            let text = document.package.text(for: path)
            let ranges = Self.findRanges(in: text, query: query, isCaseSensitive: isCaseSensitive)
            guard !ranges.isEmpty else { continue }
            let mutable = NSMutableString(string: text)
            for range in ranges.reversed() {
                mutable.replaceCharacters(in: range, with: replacement)
            }
            applyReplacedText(mutable as String, for: path)
        }
    }

    /// Writes `newText` back to `path`, routing through the editor when it is the
    /// open file so the change is visible and recompiled, otherwise mutating the
    /// package directly (which schedules the directory write-through).
    private func applyReplacedText(_ newText: String, for path: String) {
        if path == selectedPath {
            sourceText = newText
            updateSource(newText)
        } else {
            do {
                try withoutDocumentUndo {
                    try document.package.updateText(newText, for: path)
                }
            } catch {
                recordLog("Replace failed", message: error.localizedDescription, level: .error, present: true)
            }
        }
    }

    private func requestLanguageIntelligence(
        forceCompletion: Bool = false,
        allowAutomaticCompletion: Bool = true,
        selectionRange: NSRange? = nil
    ) {
        DispatchQueue.main.async {
            performLanguageIntelligenceRequest(
                forceCompletion: forceCompletion,
                allowAutomaticCompletion: allowAutomaticCompletion,
                selectionRange: selectionRange
            )
        }
    }

    private func performLanguageIntelligenceRequest(
        forceCompletion: Bool,
        allowAutomaticCompletion: Bool,
        selectionRange: NSRange?
    ) {
        languageRequestTask?.cancel()
        let requestID = UUID()
        languageRequestID = requestID
        let path = selectedPath
        let range = clampedRange(
            selectionRange ?? selectedRange ?? NSRange(location: document.package.state.cursorLocation, length: document.package.state.cursorLength),
            in: sourceText
        )
        let text = sourceText
        let diagnostics = sourceDiagnostics[path] ?? []
        languageRequestTask = Task {
            if !forceCompletion {
                try? await Task.sleep(for: .milliseconds(140))
            }
            guard !Task.isCancelled else { return }
            let shouldComplete = forceCompletion || (allowAutomaticCompletion && Self.shouldRequestCompletion(in: text, at: range.location))
            typesetLSPDebug(
                "async request path=\(path) offset=\(range.location) force=\(forceCompletion) auto=\(allowAutomaticCompletion) shouldComplete=\(shouldComplete)"
            )
            let rawCompletions = shouldComplete ? await languageService.completions(path: path, utf16Offset: range.location) : []
            let completions = Self.filteredCompletions(rawCompletions, in: text, at: range.location)
            typesetLSPDebug("async completions raw=\(rawCompletions.count) filtered=\(completions.count)")
            let diagnosticHover = completions.isEmpty && !forceCompletion ? Self.diagnosticHover(at: range.location, in: text, diagnostics: diagnostics) : nil
            let signature = completions.isEmpty && diagnosticHover == nil ? await languageService.signatureHelp(path: path, utf16Offset: range.location) : nil
            typesetLSPDebug("async signature=\(signature?.signatures.first?.label ?? "none") diagnosticHover=\(diagnosticHover?.info.text ?? "none")")
            let hover: TypstHoverInfo?
            if forceCompletion || !completions.isEmpty || diagnosticHover != nil || signature != nil {
                hover = nil
            } else {
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                hover = await languageService.hover(path: path, utf16Offset: range.location)
            }
            typesetLSPDebug("async hover=\(hover?.text ?? "none")")
            await MainActor.run {
                guard languageRequestID == requestID, selectedPath == path else { return }
                completionItems = completions
                selectedCompletionIndex = 0
                signatureHelp = signature
                hoverInfo = diagnosticHover?.info ?? Self.filteredHover(hover, in: text)
                hoverDiagnosticSeverity = diagnosticHover?.severity
            }
        }
    }

    private func requestLanguageIntelligenceForCurrentSelection(
        forceCompletion: Bool,
        allowAutomaticCompletion: Bool,
        selectionRange: NSRange? = nil
    ) async {
        let path = selectedPath
        let range = clampedRange(
            selectionRange ?? selectedRange ?? NSRange(location: document.package.state.cursorLocation, length: document.package.state.cursorLength),
            in: sourceText
        )
        let text = sourceText
        let requestID = UUID()
        await MainActor.run {
            languageRequestID = requestID
        }
        let shouldComplete = forceCompletion || (allowAutomaticCompletion && Self.shouldRequestCompletion(in: text, at: range.location))
        typesetLSPDebug(
            "direct request path=\(path) offset=\(range.location) force=\(forceCompletion) auto=\(allowAutomaticCompletion) shouldComplete=\(shouldComplete)"
        )
        let rawCompletions = shouldComplete ? await languageService.completions(path: path, utf16Offset: range.location) : []
        let completions = Self.filteredCompletions(rawCompletions, in: text, at: range.location)
        typesetLSPDebug("direct completions raw=\(rawCompletions.count) filtered=\(completions.count)")
        let diagnosticHover = completions.isEmpty && !forceCompletion
            ? Self.diagnosticHover(at: range.location, in: text, diagnostics: sourceDiagnostics[path] ?? [])
            : nil
        let signature = completions.isEmpty && diagnosticHover == nil ? await languageService.signatureHelp(path: path, utf16Offset: range.location) : nil
        typesetLSPDebug("direct signature=\(signature?.signatures.first?.label ?? "none") diagnosticHover=\(diagnosticHover?.info.text ?? "none")")
        let hover = completions.isEmpty && diagnosticHover == nil && signature == nil && !forceCompletion ? await languageService.hover(path: path, utf16Offset: range.location) : nil
        typesetLSPDebug("direct hover=\(hover?.text ?? "none")")
        await MainActor.run {
            guard languageRequestID == requestID, selectedPath == path else { return }
            completionItems = completions
            selectedCompletionIndex = 0
            signatureHelp = signature
            hoverInfo = diagnosticHover?.info ?? Self.filteredHover(hover, in: text)
            hoverDiagnosticSeverity = diagnosticHover?.severity
        }
    }

    private static func filteredHover(_ hover: TypstHoverInfo?, in text: String) -> TypstHoverInfo? {
        guard let hover else { return nil }
        guard hover.text.hasPrefix("Typst symbol `") else {
            return hover
        }
        return isCodeContext(for: hover.range, in: text) ? hover : nil
    }

    private static func diagnosticHover(at location: Int, in text: String, diagnostics: [TypstSourceDiagnostic]) -> (info: TypstHoverInfo, severity: TypstDiagnosticSeverity)? {
        let nsText = text as NSString
        let clampedLocation = min(max(0, location), nsText.length)
        guard let diagnostic = diagnostics.first(where: { diagnosticContains(location: clampedLocation, diagnostic: $0, in: nsText) }) else {
            return nil
        }

        return (
            info: TypstHoverInfo(
                range: diagnostic.range,
                text: diagnostic.message
            ),
            severity: diagnostic.severity
        )
    }

    private static func diagnosticContains(location: Int, diagnostic: TypstSourceDiagnostic, in nsText: NSString) -> Bool {
        let diagnosticLocation = min(max(0, diagnostic.range.location), nsText.length)
        let diagnosticLength = min(max(1, diagnostic.range.length), max(0, nsText.length - diagnosticLocation))
        let diagnosticRange = NSRange(location: diagnosticLocation, length: diagnosticLength)
        if NSLocationInRange(location, diagnosticRange) || location == NSMaxRange(diagnosticRange) {
            return true
        }

        let lineRange = nsText.lineRange(for: NSRange(location: diagnosticLocation, length: 0))
        return NSLocationInRange(location, lineRange) || location == NSMaxRange(lineRange)
    }

    private func insertCompletion(_ item: TypstCompletionItem) {
        guard selectedFile?.isTextEditable == true else { return }
        let range = clampedRange(
            item.replacementRange ?? completionReplacementRange(in: sourceText, at: document.package.state.cursorLocation),
            in: sourceText
        )
        let nsText = sourceText as NSString
        let insertion = completionInsertion(item, for: range, in: sourceText)
        sourceText = nsText.replacingCharacters(in: range, with: insertion.text)
        let newRange = NSRange(
            location: range.location + insertion.selectionRange.location,
            length: insertion.selectionRange.length
        )
        selectedRange = newRange
        updateSource(sourceText, selectionRange: newRange)
        clearCompletions()
    }

    private func insertFigure() {
        requestSnippetInsertion(
            template: figureInsertTemplate,
            fallback: SourceEditorDropSnippet.defaultFigureTemplate
        )
    }

    private func insertTable() {
        requestSnippetInsertion(
            template: tableInsertTemplate,
            fallback: SourceEditorDropSnippet.defaultTableTemplate
        )
    }

    /// Hands the insertion to the editor (via a one-shot request) so it goes
    /// through the text view: the edit is undoable and wraps the live selection.
    private func requestSnippetInsertion(template: String, fallback: String) {
        guard selectedFile?.isTextEditable == true else { return }
        if selectedView == .preview {
            selectedView = isCompactWidth ? .source : .both
        }
        focusSourceEditor()
        snippetInsertionToken += 1
        snippetInsertion = EditorSnippetInsertion(
            token: snippetInsertionToken,
            template: template,
            fallback: fallback
        )
    }

    private func moveCompletionSelection(by delta: Int) {
        guard !completionItems.isEmpty else { return }
        let visibleCount = min(completionItems.count, 8)
        selectedCompletionIndex = (selectedCompletionIndex + delta + visibleCount) % visibleCount
    }

    private func acceptSelectedCompletion() {
        guard !completionItems.isEmpty else { return }
        insertCompletion(completionItems[min(selectedCompletionIndex, completionItems.count - 1)])
    }

    private var findMatchRanges: [NSRange] {
        Self.findRanges(in: sourceText, query: findText, isCaseSensitive: findIsCaseSensitive)
    }

    private var currentFindMatchDisplayIndex: Int? {
        let range = currentEditorRange
        return findMatchRanges.firstIndex { NSEqualRanges($0, range) }.map { $0 + 1 }
    }

    private var currentEditorRange: NSRange {
        if let pendingEditorState, pendingEditorState.selectedFile == selectedPath {
            return clampedRange(
                NSRange(location: pendingEditorState.cursorLocation, length: pendingEditorState.cursorLength),
                in: sourceText
            )
        }

        return clampedRange(
            selectedRange ?? NSRange(
                location: document.package.state.cursorLocation,
                length: document.package.state.cursorLength
            ),
            in: sourceText
        )
    }

    private func showFindReplace() {
        guard selectedFile?.isTextEditable == true else { return }
        if selectedView == .preview {
            selectedView = .source
        }

        let range = currentEditorRange
        if range.length > 0 {
            findText = (sourceText as NSString).substring(with: range)
        }
        isFindReplacePresented = true
        selectFirstFindMatch()
    }

    private func selectFirstFindMatch() {
        guard isFindReplacePresented, !findText.isEmpty else { return }
        selectFindMatch(startingAt: currentEditorRange.location, direction: .next)
    }

    private func selectFindMatch(direction: FindDirection) {
        guard selectedFile?.isTextEditable == true else { return }
        if !isFindReplacePresented {
            showFindReplace()
            return
        }

        let range = currentEditorRange
        let startLocation: Int
        switch direction {
        case .next:
            startLocation = range.length > 0 ? NSMaxRange(range) : range.location
        case .previous:
            startLocation = range.location
        }
        selectFindMatch(startingAt: startLocation, direction: direction)
    }

    private func selectFindMatch(startingAt location: Int, direction: FindDirection) {
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return }

        let clampedLocation = min(max(0, location), (sourceText as NSString).length)
        let targetRange: NSRange
        switch direction {
        case .next:
            targetRange = ranges.first { $0.location >= clampedLocation } ?? ranges[0]
        case .previous:
            targetRange = ranges.last { NSMaxRange($0) <= clampedLocation } ?? ranges[ranges.count - 1]
        }

        selectedRange = targetRange
        clearCompletions()
        hoverInfo = nil
        hoverDiagnosticSeverity = nil
        signatureHelp = nil
    }

    private func replaceCurrentFindMatch() {
        guard selectedFile?.isTextEditable == true, !findText.isEmpty else { return }
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return }

        let current = currentEditorRange
        let replacementRange = ranges.first { NSEqualRanges($0, current) }
            ?? ranges.first { $0.location >= current.location }
            ?? ranges[0]
        let nsText = sourceText as NSString
        sourceText = nsText.replacingCharacters(in: replacementRange, with: replaceText)

        let nextLocation = replacementRange.location + (replaceText as NSString).length
        updateSource(sourceText, selectionRange: NSRange(location: nextLocation, length: 0))
        DispatchQueue.main.async {
            self.selectFindMatch(startingAt: nextLocation, direction: .next)
        }
    }

    private func replaceAllFindMatches() {
        guard selectedFile?.isTextEditable == true, !findText.isEmpty else { return }
        let ranges = findMatchRanges
        guard !ranges.isEmpty else { return }

        let mutableText = NSMutableString(string: sourceText)
        for range in ranges.reversed() {
            mutableText.replaceCharacters(in: range, with: replaceText)
        }
        sourceText = mutableText as String
        let newRange = NSRange(location: min(ranges[0].location, (sourceText as NSString).length), length: 0)
        selectedRange = newRange
        updateSource(sourceText, selectionRange: newRange)
    }

    private func clearCompletions() {
        languageRequestTask?.cancel()
        completionItems = []
        selectedCompletionIndex = 0
        signatureHelp = nil
        hoverInfo = nil
        hoverDiagnosticSeverity = nil
    }

    private func seekToDiagnostic(_ diagnostic: TypstSourceDiagnostic) {
        if selectedView == .preview {
            selectedView = .source
        }
        select(diagnostic.file)

        let diagnosticRange = clampedRange(diagnostic.range, in: document.package.text(for: diagnostic.file))
        DispatchQueue.main.async {
            guard selectedPath == diagnostic.file else { return }
            selectedRange = diagnosticRange
            withAnimation(.snappy(duration: 0.24)) {
                isLogPresented = false
            }
        }
    }

    private func completionReplacementRange(in text: String, at location: Int) -> NSRange {
        let nsText = text as NSString
        let clampedLocation = min(max(0, location), nsText.length)
        var start = clampedLocation
        while start > 0, Self.isCompletionCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: clampedLocation - start)
    }

    private static func filteredCompletions(_ completions: [TypstCompletionItem], in text: String, at location: Int) -> [TypstCompletionItem] {
        let nsText = text as NSString
        let range = completionFilterRange(in: nsText, at: location)
        let typedPrefix = range.length > 0 ? nsText.substring(with: range) : ""
        return TypstCompletionRanking.filteredAndSorted(completions, typedPrefix: typedPrefix)
    }

    private static func completionFilterRange(in nsText: NSString, at location: Int) -> NSRange {
        let clampedLocation = min(max(0, location), nsText.length)
        var start = clampedLocation
        while start > 0, isCompletionCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: clampedLocation - start)
    }

    private func completionInsertion(_ item: TypstCompletionItem, for range: NSRange, in text: String) -> TypstResolvedCompletionInsertion {
        let resolved = TypstCompletionSnippet.resolve(item.insertText, format: item.insertTextFormat)
        let nsText = text as NSString
        guard range.location > 0,
              nsText.character(at: range.location - 1) == 35,
              resolved.text.hasPrefix("#") else {
            return resolved
        }
        return TypstResolvedCompletionInsertion(
            text: String(resolved.text.dropFirst()),
            selectionRange: NSRange(
                location: max(0, resolved.selectionRange.location - 1),
                length: resolved.selectionRange.length
            )
        )
    }

    private static func shouldRequestCompletion(in text: String, at location: Int) -> Bool {
        let nsText = text as NSString
        let clampedLocation = min(max(0, location), nsText.length)
        guard clampedLocation > 0 else { return false }
        let previous = nsText.character(at: clampedLocation - 1)
        guard isCompletionCharacter(previous) else {
            return false
        }

        let prefixLength = completionPrefixLength(in: nsText, endingAt: clampedLocation)
        let prefixStart = clampedLocation - prefixLength
        let isCommandCandidate: Bool
        if prefixStart > 0 {
            let sigil = nsText.character(at: prefixStart - 1)
            isCommandCandidate = sigil == 35 || sigil == 64
        } else {
            isCommandCandidate = false
        }
        guard prefixLength >= (isCommandCandidate ? 1 : 2) else { return false }

        let prefixRange = NSRange(location: clampedLocation - prefixLength, length: prefixLength)
        if isCodeContext(for: prefixRange, in: text) {
            return true
        }
        return isMarkupCompletionContext(for: prefixRange, in: text)
    }

    private static func completionPrefixLength(in nsText: NSString, endingAt location: Int) -> Int {
        var start = location
        while start > 0, isCompletionCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        return location - start
    }

    private static func isCodeContext(for range: NSRange, in text: String) -> Bool {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return false }
        let location = min(max(0, range.location), length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let line = nsText.substring(with: lineRange)
        let prefixLength = max(0, location - lineRange.location)
        let linePrefix = (line as NSString).substring(to: min(prefixLength, (line as NSString).length))
        let trimmedPrefix = linePrefix.trimmingCharacters(in: .whitespaces)

        if trimmedPrefix.hasPrefix("#") || trimmedPrefix.hasPrefix("//") {
            return true
        }
        if linePrefix.contains("#") || linePrefix.contains("@") {
            return true
        }

        var cursor = location
        while cursor > lineRange.location {
            cursor -= 1
            let character = nsText.character(at: cursor)
            if CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(character) ?? "\0") {
                continue
            }
            return character == 35 || character == 46 || character == 64 || character == 60
        }
        return false
    }

    private static func isMarkupCompletionContext(for range: NSRange, in text: String) -> Bool {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return false }
        let location = min(max(0, range.location), length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let linePrefixLength = max(0, location - lineRange.location)
        let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: linePrefixLength))
        let trimmedPrefix = linePrefix.trimmingCharacters(in: .whitespaces)
        guard !trimmedPrefix.hasPrefix("//") else { return false }
        guard unescapedBacktickCount(in: linePrefix) % 2 == 0 else { return false }
        guard unescapedQuoteCount(in: linePrefix) % 2 == 0 else { return false }

        if location == lineRange.location {
            return true
        }

        let precedingRange = NSRange(location: lineRange.location, length: max(0, location - lineRange.location))
        let precedingText = nsText.substring(with: precedingRange)
        guard let previous = precedingText.reversed().first else { return true }
        return previous.isWhitespace
            || previous == "\n"
            || previous == "\r"
            || previous == "["
            || previous == "("
            || previous == "{"
    }

    private static func unescapedQuoteCount(in text: String) -> Int {
        unescapedCount(of: "\"", in: text)
    }

    private static func unescapedBacktickCount(in text: String) -> Int {
        unescapedCount(of: "`", in: text)
    }

    private static func unescapedCount(of target: Character, in text: String) -> Int {
        var count = 0
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == target {
                count += 1
            }
        }
        return count
    }

    private static func isCompletionCharacter(_ character: unichar) -> Bool {
        CharacterSet.alphanumerics.contains(UnicodeScalar(character) ?? "\0") || character == 95 || character == 45
    }

    private func mergeDiagnostics(_ diagnostics: [TypstSourceDiagnostic]) {
        sourceDiagnostics = Dictionary(grouping: diagnostics, by: \.file)
    }

    private func compilerDiagnostics(from message: String) -> [TypstSourceDiagnostic] {
        TypstCompilerDiagnosticParser.parse(message, defaultFile: document.package.compileTargetPath).map { diagnostic in
            let normalizedFilePath = packagePath(forCompilerDiagnosticFile: diagnostic.file)
            guard let file = document.package.files.first(where: { $0.path == normalizedFilePath }) else {
                return diagnostic
            }
            return TypstSourceDiagnostic(
                file: normalizedFilePath,
                range: rangeForLineColumn(lineIndex: diagnostic.range.location, columnIndex: diagnostic.range.length, in: String(decoding: file.data, as: UTF8.self)),
                severity: diagnostic.severity,
                message: diagnostic.message
            )
        }
    }

    private func packagePath(forCompilerDiagnosticFile file: String) -> String {
        if document.package.files.contains(where: { $0.path == file }) {
            return file
        }

        if let suffixMatch = document.package.files.first(where: { file.hasSuffix("/" + $0.path) }) {
            return suffixMatch.path
        }

        let matchingBasenames = document.package.files.filter { $0.name == URL(fileURLWithPath: file).lastPathComponent }
        if matchingBasenames.count == 1, let match = matchingBasenames.first {
            return match.path
        }

        return file
    }

    private func rangeForLineColumn(lineIndex: Int, columnIndex: Int, in text: String) -> NSRange {
        let nsText = text as NSString
        var currentLine = 0
        var result = NSRange(location: 0, length: min(1, nsText.length))
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, stop in
            if currentLine == lineIndex {
                result = NSRange(location: min(lineRange.location + columnIndex, NSMaxRange(lineRange)), length: 1)
                stop.pointee = true
            }
            currentLine += 1
        }
        return result
    }

    private func seek(to range: SourceRange) {
        select(range.path)
        selectedRange = NSRange(location: range.start, length: max(0, range.end - range.start))
        if selectedView == .preview {
            selectedView = .source
        }
    }

    private func exportPDF() {
        let runID = beginDiagnosticRun()
        let package = packageSnapshotForExport()
        let renderer = self.renderer
        Task {
            do {
                #if os(iOS)
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "TypesetExports", directoryHint: .isDirectory)
                    .appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let outputURL = directory.appending(path: defaultPDFExportFilename())
                try await renderer.exportPDF(package: package, to: outputURL)
                await MainActor.run {
                    guard diagnosticRunID == runID else { return }
                    pdfShareItem = PDFShareItem(url: outputURL)
                    logEntries.removeAll()
                }
                #else
                let outputURL = FileManager.default.temporaryDirectory
                    .appending(path: "Typeset-\(UUID().uuidString).pdf")
                try await renderer.exportPDF(package: package, to: outputURL)
                let data = try Data(contentsOf: outputURL)
                await MainActor.run {
                    guard diagnosticRunID == runID else { return }
                    exportDocument = PDFExportDocument(data: data)
                    exportDefaultFilename = defaultPDFExportFilename()
                    isExportPresented = true
                    logEntries.removeAll()
                }
                #endif
            } catch {
                await MainActor.run {
                    recordLog(
                        "PDF export failed",
                        message: error.localizedDescription,
                        level: .error,
                        runID: runID,
                        present: true
                    )
                }
            }
        }
    }

    private func exportPDFToDefaultLocation() {
        guard canExportPDFToDefaultLocation else {
            recordLog(
                "PDF export failed",
                message: "Default-location PDF export requires a saved macOS document.",
                level: .error,
                present: true
            )
            return
        }

        guard let outputURL = defaultPDFExportURL else {
            recordLog(
                "PDF export failed",
                message: "Save the document before exporting to the default location.",
                level: .error,
                present: true
            )
            return
        }

        #if os(macOS)
        // The default location is the folder beside the document, which the
        // sandbox grant for the document itself does not cover.
        let exportFolder = outputURL.deletingLastPathComponent()
        guard FolderAccessStore.ensureAccess(
            to: exportFolder,
            requiresWrite: true,
            message: "Typeset saves “\(outputURL.lastPathComponent)” next to your document. Grant access to “\(exportFolder.lastPathComponent)” to export there."
        ) else {
            recordLog(
                "PDF export failed",
                message: "Typeset doesn't have permission to write into \(exportFolder.path).",
                level: .error,
                present: true
            )
            return
        }
        #endif

        exportPDFDirectly(to: outputURL, presentErrors: true)
    }

    private func exportPDFOnCloseIfNeeded() {
        guard canExportPDFToDefaultLocation, autoExportPDFOnClose, !didAutoExportPDFOnDisappear else { return }
        guard let outputURL = defaultPDFExportURL else { return }

        #if os(macOS)
        // Closing is no moment for a permission prompt; export only when a
        // stored grant already covers the destination folder.
        let exportFolder = outputURL.deletingLastPathComponent()
        guard FolderAccessStore.hasAccess(to: exportFolder, requiresWrite: true) else {
            print("Typeset PDF export on close skipped: no folder permission for \(exportFolder.path)")
            return
        }
        #endif

        didAutoExportPDFOnDisappear = true
        let package = packageSnapshotForExport()
        let renderer = self.renderer
        Task {
            do {
                let accessURL = outputURL.deletingLastPathComponent()
                let didAccess = accessURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        accessURL.stopAccessingSecurityScopedResource()
                    }
                }

                try await renderer.exportPDF(package: package, to: outputURL)
            } catch {
                print("Typeset PDF export on close failed: \(error.localizedDescription)")
            }
        }
    }

    private func exportPDFDirectly(to outputURL: URL, presentErrors: Bool) {
        let runID = beginDiagnosticRun()
        let package = packageSnapshotForExport()
        let renderer = self.renderer
        Task {
            do {
                let accessURL = outputURL.deletingLastPathComponent()
                let didAccess = accessURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        accessURL.stopAccessingSecurityScopedResource()
                    }
                }

                try await renderer.exportPDF(package: package, to: outputURL)
                await MainActor.run {
                    guard diagnosticRunID == runID else { return }
                    recordLog(
                        "PDF exported",
                        message: outputURL.path,
                        level: .info,
                        runID: runID
                    )
                }
            } catch {
                await MainActor.run {
                    guard diagnosticRunID == runID else { return }
                    recordLog(
                        "PDF export failed",
                        message: error.localizedDescription,
                        level: .error,
                        runID: runID,
                        present: presentErrors
                    )
                }
            }
        }
    }

    private func packageSnapshotForExport() -> DocumentPackage {
        var package = document.package
        if selectedFile?.isTextEditable == true {
            try? package.updateSelectedText(sourceText)
        }
        return package
    }

    private func prepareNewFolder() {
        let parent = folderCreationParent
        for attempt in 1...999 {
            let name = attempt == 1 ? "Untitled Folder" : "Untitled Folder \(attempt)"
            do {
                let path = try document.package.createFolder(named: name, in: parent)
                expandFolderIfNeeded(parent)
                selectedFolderPath = path
                pendingFileTreeEdit = .folder(path)
                setFileSidebarPresented(true)
                syncLanguageServiceWorkspace()
                return
            } catch TypesetPackageError.folderAlreadyExists(_) {
                continue
            } catch {
                recordLog("Folder creation failed", message: error.localizedDescription, level: .error, present: true)
                return
            }
        }

        recordLog("Folder creation failed", message: "Could not find an available folder name.", level: .error, present: true)
    }

    private func prepareNewFile() {
        let parent = folderCreationParent
        do {
            let path = try document.package.addFile(
                named: "Untitled.typ",
                data: Data(),
                in: parent
            )
            expandFolderIfNeeded(parent)
            select(path)
            pendingFileTreeEdit = .file(path)
            setFileSidebarPresented(true)
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("File creation failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func expandFolderIfNeeded(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        var expandedFolders = Set(document.package.state.expandedFolders)
        expandedFolders.insert(path)
        document.package.updateExpandedFolders(Array(expandedFolders))
    }

    private func moveFile(_ path: String, toFolder folder: String?) {
        do {
            _ = try document.package.moveFile(
                at: path,
                toFolder: folder,
                updatingReferences: updateReferencesOnRename
            )
            refreshSelectedSourceFromPackage()
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Move failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func moveFolder(_ path: String, toFolder folder: String?) {
        do {
            let movedPath = try document.package.moveFolder(
                at: path,
                toFolder: folder,
                updatingReferences: updateReferencesOnRename
            )
            if let selectedFolderPath {
                self.selectedFolderPath = Self.pathByReplacingPrefix(
                    selectedFolderPath,
                    sourcePrefix: path,
                    destinationPrefix: movedPath
                )
            }
            refreshSelectedSourceFromPackage()
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Move failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func importExternalFiles(_ urls: [URL], toFolder folder: String?, copyOriginals: Bool) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            var didImport = false

            for url in urls {
                do {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }

                    let data = try Data(contentsOf: url)
                    _ = try document.package.addFile(
                        named: url.lastPathComponent,
                        data: data,
                        in: folder
                    )
                    didImport = true

                    if !copyOriginals {
                        try? FileManager.default.removeItem(at: url)
                    }
                } catch {
                    recordLog("Import failed", message: "\(url.lastPathComponent): \(error.localizedDescription)", level: .error, present: true)
                }
            }

            if didImport {
                syncLanguageServiceWorkspace()
                refreshPreview()
            }
        }
    }

    /// Imports photos chosen from the system Photos library into the package.
    /// Library assets are frequently HEIC/HEIF, which Typst cannot render, so
    /// anything that isn't already a Typst-friendly format is transcoded to PNG
    /// before it lands in the package. New files go into the currently selected
    /// folder (matching the file importer), and `addFile` de-duplicates names.
    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let folder = folderCreationParent

        Task { @MainActor in
            var didImport = false

            for (index, item) in items.enumerated() {
                do {
                    guard let rawData = try await item.loadTransferable(type: Data.self) else {
                        recordLog("Photo import failed", message: "Could not load the selected photo.", level: .error, present: true)
                        continue
                    }

                    guard let normalized = Self.typstFriendlyImageData(rawData, contentType: item.supportedContentTypes.first) else {
                        recordLog("Photo import failed", message: "The selected photo is in an unsupported format.", level: .error, present: true)
                        continue
                    }

                    let baseName = items.count > 1 ? "Photo \(index + 1)" : "Photo"
                    _ = try document.package.addFile(
                        named: "\(baseName).\(normalized.ext)",
                        data: normalized.data,
                        in: folder
                    )
                    didImport = true
                } catch {
                    recordLog("Photo import failed", message: error.localizedDescription, level: .error, present: true)
                }
            }

            if didImport {
                syncLanguageServiceWorkspace()
                refreshPreview()
            }
        }
    }

    /// Returns image data in a format Typst can render. PNG/JPEG/GIF/SVG pass
    /// through unchanged; everything else (HEIC/HEIF/TIFF/RAW/…) is decoded and
    /// re-encoded as JPEG — the right choice for the photographic content these
    /// formats hold (far smaller than PNG, and these sources have no alpha to
    /// preserve). Returns `nil` only if the data can't be decoded as an image.
    private static func typstFriendlyImageData(_ data: Data, contentType: UTType?) -> (data: Data, ext: String)? {
        if let contentType {
            if contentType.conforms(to: .png) { return (data, "png") }
            if contentType.conforms(to: .jpeg) { return (data, "jpg") }
            if contentType.conforms(to: .gif) { return (data, "gif") }
            if contentType.conforms(to: .svg) { return (data, "svg") }
        }

        #if os(macOS)
        guard let rep = NSBitmapImageRep(data: data),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        return (jpeg, "jpg")
        #else
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return (jpeg, "jpg")
        #endif
    }

    @MainActor
    private func importExternalFileForSourceDrop(_ url: URL) -> String? {
        do {
            if let packagePath = packagePath(forFileURL: url),
               document.package.files.contains(where: { $0.path == packagePath }) {
                return packagePath
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let importedPath = try document.package.addFile(
                named: url.lastPathComponent,
                data: data,
                in: nil
            )
            syncLanguageServiceWorkspace()
            refreshPreview()
            return importedPath
        } catch {
            recordLog("Import failed", message: "\(url.lastPathComponent): \(error.localizedDescription)", level: .error, present: true)
            return nil
        }
    }

    @MainActor
    private func importPastedImageForSourcePaste(data: Data, suggestedName: String) -> String? {
        do {
            let importedPath = try document.package.addFile(
                named: suggestedName,
                data: data,
                in: nil
            )
            syncLanguageServiceWorkspace()
            refreshPreview()
            return importedPath
        } catch {
            recordLog("Paste failed", message: "\(suggestedName): \(error.localizedDescription)", level: .error, present: true)
            return nil
        }
    }

    private func renameFile(_ path: String, to name: String) {
        do {
            _ = try document.package.renameFile(
                at: path,
                to: name,
                updatingReferences: updateReferencesOnRename
            )
            refreshSelectedSourceFromPackage()
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Rename failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func renameFolder(_ path: String, to name: String) {
        do {
            let renamedPath = try document.package.renameFolder(
                at: path,
                to: name,
                updatingReferences: updateReferencesOnRename
            )
            if let selectedFolderPath {
                self.selectedFolderPath = Self.pathByReplacingPrefix(
                    selectedFolderPath,
                    sourcePrefix: path,
                    destinationPrefix: renamedPath
                )
            }
            refreshSelectedSourceFromPackage()
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Rename failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func refreshSelectedSourceFromPackage() {
        selectedPath = document.package.selectedPath
        sourceText = document.package.text(for: selectedPath)
    }

    private func reconcileViewStateWithPackage() {
        let packageSelectedPath = document.package.files.contains(where: { $0.path == selectedPath })
            ? selectedPath
            : document.package.selectedPath
        var didReconcile = false

        if selectedPath != packageSelectedPath {
            selectedPath = packageSelectedPath
            selectedRange = nil
            didReconcile = true
        }

        let packageText = document.package.text(for: packageSelectedPath)
        if sourceText != packageText {
            sourceText = packageText
            didReconcile = true
        }

        guard didReconcile else { return }
        clearCompletions()
        hoverInfo = nil
        hoverDiagnosticSeverity = nil
        signatureHelp = nil
        syncLanguageServiceWorkspace()
        refreshPreview()
    }

    private func deleteFile(_ path: String) {
        do {
            try document.package.deleteFile(at: path)
            if selectedPath == path {
                selectedPath = ""
                sourceText = ""
                selectedRange = nil
                select(document.package.selectedPath, restoringEditorState: true)
            }
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Delete failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func duplicateFile(_ path: String) {
        guard let original = document.package.files.first(where: { $0.path == path }) else { return }
        let components = path.split(separator: "/").map(String.init)
        let folder = components.count > 1 ? components.dropLast().joined(separator: "/") : nil
        let fileName = components.last ?? path
        let base: String
        let ext: String
        if let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex {
            base = String(fileName[..<dot])
            ext = String(fileName[dot...])
        } else {
            base = fileName
            ext = ""
        }
        do {
            // `addFile` de-duplicates, so a second copy becomes "… copy 2".
            let newPath = try document.package.addFile(
                named: "\(base) copy\(ext)",
                data: original.data,
                in: folder
            )
            // Only switch the editor to the copy when it's text-editable. A
            // duplicated PDF/image isn't an editor target — selecting it would
            // swap the editor for an asset preview and decode binary as UTF-8.
            if document.package.files.first(where: { $0.path == newPath })?.isTextEditable == true {
                select(newPath)
            }
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Duplicate failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func deleteFolder(_ path: String) {
        do {
            try document.package.deleteFolder(at: path)
            if selectedFolderPath == path || selectedFolderPath?.hasPrefix(path + "/") == true {
                selectedFolderPath = nil
            }
            if selectedPath != document.package.selectedPath {
                selectedPath = ""
                sourceText = ""
                selectedRange = nil
                select(document.package.selectedPath, restoringEditorState: true)
            }
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Delete failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func setCompileTarget(_ path: String) {
        guard canSetCompileTarget else { return }
        do {
            try document.package.setCompileTarget(path: path)
            syncLanguageServiceWorkspace()
            refreshPreview()
        } catch {
            recordLog("Target selection failed", message: error.localizedDescription, level: .error, present: true)
        }
    }

    private func runPythonScriptInTerminal(_ path: String) {
        #if os(macOS)
        guard let file = document.package.files.first(where: { $0.path == path }),
              file.isPythonScript else {
            return
        }

        guard let packageRootURL else {
            recordLog(
                "Run failed",
                message: "Save the document before running a Python script from the package.",
                level: .error,
                present: true
            )
            return
        }

        let scriptURL = packageRootURL
            .appendingPathComponent(path)
            .standardizedFileURL
        let didAccess = packageRootURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                packageRootURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: scriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: scriptURL, options: .atomic)

            let launcherURL = try Self.makePythonTerminalLauncher(for: scriptURL)
            NSWorkspace.shared.open(launcherURL)
        } catch {
            recordLog("Run failed", message: error.localizedDescription, level: .error, present: true)
        }
        #else
        recordLog(
            "Run unavailable",
            message: "Python scripts can be run in Terminal on macOS.",
            level: .error,
            present: true
        )
        #endif
    }

    #if os(macOS)
    private static func makePythonTerminalLauncher(for scriptURL: URL) throws -> URL {
        let launcherDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypesetScriptRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)

        let launcherURL = launcherDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("command")
        let workingDirectory = scriptURL.deletingLastPathComponent().path
        let scriptName = "./\(scriptURL.lastPathComponent)"
        let command = """
        #!/bin/zsh
        cd \(shellQuoted(workingDirectory)) || exit 1
        /usr/bin/env python3 -- \(shellQuoted(scriptName))
        status=$?
        printf '\\nTypeset: script exited with status %d.\\n' "$status"
        printf 'Press Return to close this window.'
        read -r _
        exit "$status"
        """

        try command.write(to: launcherURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherURL.path)
        return launcherURL
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
    #endif

    private static func isImageFile(path: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }

        return type.conforms(to: .image)
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

    private func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), max(0, length - location)))
    }

    private static func findRanges(in text: String, query: String, isCaseSensitive: Bool) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let nsText = text as NSString
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.location < nsText.length {
            let foundRange = nsText.range(of: query, options: options, range: searchRange)
            guard foundRange.location != NSNotFound else { break }
            ranges.append(foundRange)

            let nextLocation = foundRange.location + max(1, foundRange.length)
            searchRange = NSRange(location: nextLocation, length: max(0, nsText.length - nextLocation))
        }

        return ranges
    }

    private func defaultPDFExportFilename() -> String {
        let mainPath = document.package.mainTypstPath ?? document.package.compileTargetPath
        let baseName = URL(fileURLWithPath: mainPath)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(baseName.isEmpty ? "Typeset Export" : baseName).pdf"
    }

    private var defaultPDFExportURL: URL? {
        guard let documentURL = fileURL ?? loadedTypstDirectoryFileURL else { return nil }
        return documentURL
            .deletingLastPathComponent()
            .appending(path: defaultPDFExportFilename())
            .standardizedFileURL
    }

    private var supportsPDFExport: Bool {
        #if os(macOS) || os(iOS)
        true
        #else
        false
        #endif
    }

    private var canExportPDFToDefaultLocation: Bool {
        #if os(macOS)
        supportsPDFExport && defaultPDFExportURL != nil
        #else
        false
        #endif
    }

    private func beginDiagnosticRun() -> UUID {
        let runID = UUID()
        diagnosticRunID = runID
        logEntries.removeAll()
        return runID
    }

    private var languageServiceDocumentID: String {
        if let fileURL {
            return String(abs(fileURL.standardizedFileURL.path.hashValue))
        }
        return String(abs(document.package.compileTargetPath.hashValue))
    }

    private func recordLog(_ title: String, message: String, level: DiagnosticLogEntry.Level, runID: UUID? = nil, present: Bool = false) {
        if let runID, diagnosticRunID != runID {
            return
        }
        logEntries = [DiagnosticLogEntry(title: title, message: message, level: level)]
    }

    private func recordDiagnostics(_ diagnostics: [TypstSourceDiagnostic], runID: UUID? = nil, present: Bool = false) {
        if let runID, diagnosticRunID != runID {
            return
        }
        logEntries = diagnostics.map { diagnostic in
            DiagnosticLogEntry(
                title: diagnosticTitle(for: diagnostic),
                message: diagnostic.message,
                level: diagnostic.severity == .error ? .error : .warning,
                diagnostic: diagnostic
            )
        }
    }

    private func diagnosticTitle(for diagnostic: TypstSourceDiagnostic) -> String {
        let line = lineNumber(for: diagnostic.range, in: document.package.text(for: diagnostic.file))
        return "\(diagnostic.file):\(line)"
    }

    private func lineNumber(for range: NSRange, in text: String) -> Int {
        let nsText = text as NSString
        let location = min(max(0, range.location), nsText.length)
        let prefix = nsText.substring(to: location)
        return prefix.filter { $0 == "\n" }.count + 1
    }

    private var folderCreationParent: String? {
        if let selectedFolderPath {
            return selectedFolderPath
        }

        let parts = selectedPath.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "/")
    }

    private var packageRootURL: URL? {
        guard let fileURL else { return nil }
        if fileURL.pathExtension.lowercased() == "typ" {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return fileURL.standardizedFileURL
    }

    /// The on-disk folder we mirror to, or `nil` when not in directory mode
    /// (a `.typeset` package persists through the document's file wrapper instead).
    private var directoryModeRootURL: URL? {
        loadedTypstDirectoryFileURL != nil ? packageRootURL : nil
    }

    /// The package path of the opened `.typ` — the file the SwiftUI document
    /// (FileDocument/DocumentGroup) persists itself and whose modification date
    /// it tracks. Our directory write-through and watcher leave it ENTIRELY to
    /// the document machinery: writing it ourselves desyncs that tracking and
    /// triggers a spurious "the file has been changed by another application" on
    /// the next save.
    private var documentManagedPath: String? {
        guard loadedTypstDirectoryFileURL != nil else { return nil }
        return loadedTypstDirectoryFileURL.flatMap { packagePath(forFileURL: $0) }
    }

    /// Records the package's current files/folders as the on-disk baseline
    /// without writing anything — used right after loading a folder, since the
    /// package already matches disk at that point. The document-managed file is
    /// excluded so our subsystem never tracks (and thus never deletes/rewrites) it.
    private func resetDiskSnapshotFromPackage() {
        let managed = documentManagedPath
        diskFileSnapshot = Dictionary(
            document.package.files.filter { $0.path != managed }.map { ($0.path, $0.data.hashValue) },
            uniquingKeysWith: { first, _ in first }
        )
        diskFolderSnapshot = Set(document.package.allFolderPaths)
        // The freshly loaded package matches disk, so the opened file's bytes are
        // the agreed baseline for its external-change detection.
        managedFileDiskHash = managed.flatMap { path in
            document.package.files.first { $0.path == path }?.data.hashValue
        }
    }

    private func scheduleDirectorySync() {
        guard directoryModeRootURL != nil else { return }
        directorySyncTask?.cancel()
        directorySyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            syncDirectoryToDisk()
        }
    }

    /// Mirrors the in-memory package back to the real folder: writes new and
    /// changed files, creates new folders, and removes files/folders that were
    /// previously ours but have since been deleted/renamed/moved out of the
    /// package. Removals are scoped to the snapshot, so a file that exists on
    /// disk but was never part of the package is never touched.
    private func syncDirectoryToDisk(root explicitRoot: URL? = nil) {
        directorySyncTask?.cancel()
        directorySyncTask = nil
        guard let root = explicitRoot ?? directoryModeRootURL else { return }
        let fileManager = FileManager.default
        let currentFolders = Set(document.package.allFolderPaths)

        // 1. Create newly added folders, shallowest first.
        for folder in currentFolders.subtracting(diskFolderSnapshot)
            .sorted(by: { $0.count < $1.count }) {
            try? fileManager.createDirectory(
                at: root.appending(path: folder),
                withIntermediateDirectories: true
            )
        }

        // 2. Write new and changed files.
        // A file under an unresolved conflict is frozen on disk until the user
        // decides — never let the write-through clobber the external version.
        let conflictPath = pendingConflict?.path
        let managed = documentManagedPath
        var nextSnapshot: [String: Int] = [:]
        for file in document.package.files {
            // The opened .typ is persisted by the document machinery; leave it
            // out of our writes AND our snapshot entirely.
            if file.path == managed { continue }
            let hash = file.data.hashValue
            if file.path == conflictPath {
                nextSnapshot[file.path] = diskFileSnapshot[file.path] ?? hash
                continue
            }
            nextSnapshot[file.path] = hash
            guard diskFileSnapshot[file.path] != hash else { continue }
            let url = root.appending(path: file.path)
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try file.data.write(to: url, options: .atomic)
            } catch {
                recordLog("Save failed", message: "\(file.path): \(error.localizedDescription)", level: .error, present: true)
            }
        }

        // 3. Remove files we previously managed that are gone from the package.
        for removed in Set(diskFileSnapshot.keys).subtracting(nextSnapshot.keys) {
            try? fileManager.removeItem(at: root.appending(path: removed))
        }

        // 4. Remove folders dropped from the package, deepest first.
        for removed in diskFolderSnapshot.subtracting(currentFolders)
            .sorted(by: { $0.count > $1.count }) {
            try? fileManager.removeItem(at: root.appending(path: removed))
        }

        diskFileSnapshot = nextSnapshot
        diskFolderSnapshot = currentFolders
    }

    // MARK: - External folder monitoring (#1 reflect changes, #3 conflict prompt)

    #if os(macOS)
    /// (Re)starts the folder watcher for the current directory-mode root. Safe to
    /// call repeatedly; tears down any previous watcher first.
    private func startDirectoryWatcher() {
        stopDirectoryWatcher()
        guard let root = directoryModeRootURL else { return }
        directoryWatcher = DirectoryWatcher(rootURL: root) {
            // FSEvents callback runs on a background queue; hop to the main actor.
            Task { @MainActor in
                scheduleExternalReconcile()
            }
        }
    }

    private func stopDirectoryWatcher() {
        directoryWatcher?.stop()
        directoryWatcher = nil
        externalReconcileTask?.cancel()
        externalReconcileTask = nil
    }
    #endif

    private func scheduleExternalReconcile() {
        guard directoryModeRootURL != nil else { return }
        externalReconcileTask?.cancel()
        externalReconcileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            reconcileExternalChanges()
        }
    }

    /// True when the open (selected) text file has unsaved edits relative to what
    /// we last wrote/loaded to disk. A file with no snapshot baseline is one the
    /// app just created and hasn't synced yet — treat it as unsaved so it is
    /// never silently dropped.
    private func openFileHasUnsavedEdits(_ path: String) -> Bool {
        guard selectedFile?.isTextEditable == true else { return false }
        guard let snapshotHash = diskFileSnapshot[path] else { return true }
        return Data(sourceText.utf8).hashValue != snapshotHash
    }

    /// Creates `folder` (and any missing ancestors) in `package` if absent.
    private func ensureFolderExists(_ folder: String, in package: inout DocumentPackage) {
        guard !package.allFolderPaths.contains(folder) else { return }
        var prefix = ""
        for part in folder.split(separator: "/").map(String.init) {
            let path = prefix.isEmpty ? part : "\(prefix)/\(part)"
            if !package.allFolderPaths.contains(path) {
                _ = try? package.createFolder(named: part, in: prefix.isEmpty ? nil : prefix)
            }
            prefix = path
        }
    }

    /// Re-reads the folder from disk and reconciles genuine external changes into
    /// the package/editor. Our own writes (write-through AND the SwiftUI document
    /// autosave of the open file) keep disk == the editor/snapshot, so they
    /// self-suppress; only true external changes are applied. The open file is
    /// special-cased: if it changed on disk while it has unsaved edits, we never
    /// clobber — we raise a conflict prompt instead.
    private func reconcileExternalChanges() {
        externalReconcileTask?.cancel()
        externalReconcileTask = nil
        #if os(macOS)
        // A late hop from an already-torn-down watcher must be a no-op.
        guard directoryWatcher != nil else { return }
        #endif
        // Don't reconcile while a conflict prompt is up; we re-run after it resolves.
        guard pendingConflict == nil else { return }
        guard let root = directoryModeRootURL, let openedURL = loadedTypstDirectoryFileURL else { return }

        // Re-read disk through the same loader so file filtering can't drift. A
        // transient failure (root vanished, mid atomic-rename) just bails; a later
        // event retries.
        guard var fresh = try? DocumentPackage(directoryURL: root, openedFileURL: openedURL) else {
            return
        }

        // The opened .typ is owned by the document machinery (it persists and
        // resolves conflicts for that file natively). Exclude it from our disk
        // diff/snapshot, and keep its in-app content in `fresh` so a
        // neighbor-triggered reconcile never reverts the user's edits to it.
        let managed = documentManagedPath
        // The opened document is normally left to SwiftUI, but SwiftUI has no
        // live "changed on disk" prompt, so monitor it here too. Capture its
        // on-disk bytes now, before the in-app copy below overwrites them in
        // `fresh`, and compare against the editor and the agreed baseline.
        let managedDiskText: String? = managed.flatMap { path in
            fresh.files.contains(where: { $0.path == path }) ? fresh.text(for: path) : nil
        }
        let managedEditorText: String? = managed.map { path in
            path == selectedPath ? sourceText : document.package.text(for: path)
        }
        let managedDiskHash = managedDiskText.map { Data($0.utf8).hashValue }
        // A genuine external write: disk moved off the baseline AND differs from
        // the editor (our own saves echo back as disk == editor and are ignored).
        let managedChangedExternally = managed != nil
            && managedDiskHash != managedFileDiskHash
            && managedDiskText != managedEditorText
        // Unsaved edits = the editor has moved off that same baseline.
        let managedHasUnsavedEdits =
            managedEditorText.map { Data($0.utf8).hashValue } != managedFileDiskHash
        if let managed, let inApp = document.package.files.first(where: { $0.path == managed }),
           fresh.files.contains(where: { $0.path == managed }) {
            try? fresh.updateFileData(inApp.data, for: managed)
        }

        // Snapshot the ACTUAL disk state now, before merging any in-memory-only
        // files back into `fresh`. We re-baseline to THIS, so files that exist
        // only in memory are left out of the baseline and the write-through
        // actually persists them.
        let diskHashes = Dictionary(fresh.files.filter { $0.path != managed }.map { ($0.path, $0.data.hashValue) }, uniquingKeysWith: { first, _ in first })
        let diskFolders = Set(fresh.allFolderPaths)

        // Whenever the opened file's disk bytes and the editor agree (our own
        // save echoing back, or no change at all), advance its baseline now —
        // even if the guard below returns early — so a later edit is not misread
        // as an unsaved change against a stale baseline.
        if managed != nil, let managedDiskHash, managedDiskText == managedEditorText {
            managedFileDiskHash = managedDiskHash
        }

        // Self-write echo / no genuine change. The opened file is tracked apart
        // from `diskHashes`, so check it explicitly too.
        guard diskHashes != diskFileSnapshot || diskFolders != diskFolderSnapshot
            || managedChangedExternally else { return }

        // Preserve in-app files created/imported but not yet written to disk
        // (absent from disk AND from the snapshot): merge them into `fresh` so
        // adopting it doesn't wipe freshly authored content. They're tracked as
        // `pendingWrites` and kept OUT of the disk baseline, so the next
        // write-through writes them.
        var pendingWrites: Set<String> = []
        for file in document.package.files
        where file.path != managed && diskHashes[file.path] == nil && diskFileSnapshot[file.path] == nil {
            let parts = file.path.split(separator: "/").map(String.init)
            let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            if let folder { ensureFolderExists(folder, in: &fresh) }
            if !fresh.files.contains(where: { $0.path == file.path }), let leaf = parts.last,
               let added = try? fresh.addFile(named: leaf, data: file.data, in: folder) {
                pendingWrites.insert(added)
            }
        }

        let openPath = selectedPath
        let openInPackage = fresh.files.contains { $0.path == openPath }
        let openReallyOnDisk = diskHashes[openPath] != nil
        let editorHash = Data(sourceText.utf8).hashValue
        // A genuine external change to the open file requires BOTH: (a) disk
        // changed vs our last-known baseline (else the disk merely lags our own
        // not-yet-flushed write-through and there is nothing external), AND (b)
        // disk differs from the editor (which self-suppresses our write-through
        // and the SwiftUI document autosave, both of which write the editor's
        // bytes). A file that exists only in memory has no on-disk version.
        let openDiskDiffersFromEditor = openReallyOnDisk
            && !pendingWrites.contains(openPath)
            && diskHashes[openPath] != diskFileSnapshot[openPath]
            && diskHashes[openPath] != editorHash
        let openDirty = openFileHasUnsavedEdits(openPath)
        let openDiskText = openReallyOnDisk ? fresh.text(for: openPath) : ""

        // Preserve in-app view state (directory mode keeps it in memory).
        fresh.state = document.package.state

        var conflict = false

        if openInPackage {
            fresh.selectedPath = openPath
            fresh.state.selectedFile = openPath
            if openDirty {
                // Keep the user's version in the package no matter what.
                try? fresh.updateFileData(Data(sourceText.utf8), for: openPath)
                conflict = openDiskDiffersFromEditor
            }
        } else if openDirty {
            // Open file deleted/renamed externally but has unsaved edits: re-add
            // it so the work survives. It is a pending write, so the write-through
            // re-creates it on disk.
            let parts = openPath.split(separator: "/").map(String.init)
            let folder = parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
            if let folder { ensureFolderExists(folder, in: &fresh) }
            if let leaf = parts.last,
               let added = try? fresh.addFile(named: leaf, data: Data(sourceText.utf8), in: folder) {
                pendingWrites.insert(added)
                fresh.selectedPath = added
                fresh.state.selectedFile = added
            }
        }

        // Never leave the selection pointing at a missing file. `fresh.selectedPath`
        // itself can be stale (the loader keeps the opened path even when deleted),
        // so repair it toward a guaranteed-valid file first.
        if !fresh.files.contains(where: { $0.path == fresh.selectedPath }) {
            fresh.selectedPath = fresh.compileTargetPath
        }
        if !fresh.files.contains(where: { $0.path == fresh.state.selectedFile }) {
            fresh.state.selectedFile = fresh.selectedPath
        }

        document.package = fresh

        // Clean open file changed externally -> reload its editor text from disk.
        if openDiskDiffersFromEditor, !openDirty,
           document.package.files.contains(where: { $0.path == openPath }) {
            let diskText = document.package.text(for: openPath)
            if sourceText != diskText {
                sourceText = diskText
                selectedRange = nil
                syncLanguageServiceFile(path: openPath, text: diskText, selectionRange: nil)
            }
        }

        // Re-baseline to the ACTUAL disk state (excluding in-memory-only pending
        // writes, so the write-through persists them). Keep a conflicted file
        // divergent and prompt.
        diskFileSnapshot = diskHashes
        diskFolderSnapshot = diskFolders
        if conflict {
            diskFileSnapshot[openPath] = Data(sourceText.utf8).hashValue
            pendingConflict = DiskConflict(path: openPath, diskText: openDiskText)
        }

        // The opened document, with the same policy as siblings: silently reload
        // when the editor is clean, prompt when it has unsaved edits. A sibling
        // conflict (if any) takes the single prompt first; we re-detect next pass.
        if let managed, managedChangedExternally, let managedDiskText, let managedDiskHash {
            if managedHasUnsavedEdits {
                if pendingConflict == nil {
                    pendingConflict = DiskConflict(path: managed, diskText: managedDiskText)
                }
                // Leave the baseline divergent; resolving the prompt advances it.
            } else {
                reloadManagedFileFromDisk(managed, diskText: managedDiskText)
                managedFileDiskHash = managedDiskHash
            }
        } else if let managedDiskHash {
            // No external change (or our own save echoing back): keep the baseline
            // current so the next genuine change is detected.
            managedFileDiskHash = managedDiskHash
        }

        syncLanguageServiceWorkspace()
        refreshPreview()
    }

    /// Adopt the opened document's on-disk bytes into the editor and package
    /// without writing disk (the file is SwiftUI-managed). Used both for a clean
    /// external change and for "Revert to Disk" on the opened document.
    private func reloadManagedFileFromDisk(_ path: String, diskText: String) {
        if selectedPath == path {
            sourceText = diskText
            selectedRange = nil
        }
        try? withoutDocumentUndo {
            try document.package.updateText(diskText, for: path)
        }
        syncLanguageServiceFile(path: path, text: diskText, selectionRange: nil)
        refreshPreview()
    }

    private func resolveConflictKeepingMine(_ conflict: DiskConflict) {
        // Idempotent: a button tap and the alert's dismiss-binding can both fire.
        guard pendingConflict?.id == conflict.id else { return }
        pendingConflict = nil
        // The opened document is SwiftUI-managed: don't write it ourselves (that
        // desyncs SwiftUI's change tracking). The editor keeps the user's text
        // and the document stays dirty, so SwiftUI saves it over the external
        // version. Advance the baseline to the current on-disk bytes so the same
        // external change doesn't re-prompt before that save lands.
        if conflict.path == documentManagedPath {
            managedFileDiskHash = Data(conflict.diskText.utf8).hashValue
            scheduleExternalReconcile()
            return
        }
        guard let root = directoryModeRootURL else { return }
        let data = Data(document.package.text(for: conflict.path).utf8)
        do {
            try data.write(to: root.appending(path: conflict.path), options: .atomic)
        } catch {
            recordLog("Save failed", message: "\(conflict.path): \(error.localizedDescription)", level: .error, present: true)
        }
        diskFileSnapshot[conflict.path] = data.hashValue
        // Drain any other changes batched while the prompt was up.
        scheduleExternalReconcile()
    }

    private func resolveConflictRevertingToDisk(_ conflict: DiskConflict) {
        guard pendingConflict?.id == conflict.id else { return }
        pendingConflict = nil
        // The opened document is tracked apart from `diskFileSnapshot`; adopt the
        // disk bytes and advance its own baseline instead.
        if conflict.path == documentManagedPath {
            reloadManagedFileFromDisk(conflict.path, diskText: conflict.diskText)
            managedFileDiskHash = Data(conflict.diskText.utf8).hashValue
            scheduleExternalReconcile()
            return
        }
        if selectedPath == conflict.path {
            sourceText = conflict.diskText
            selectedRange = nil
        }
        try? withoutDocumentUndo {
            try document.package.updateText(conflict.diskText, for: conflict.path)
        }
        diskFileSnapshot[conflict.path] = Data(conflict.diskText.utf8).hashValue
        syncLanguageServiceFile(path: conflict.path, text: conflict.diskText, selectionRange: nil)
        refreshPreview()
        scheduleExternalReconcile()
    }

    private func packagePath(forFileURL url: URL) -> String? {
        guard let packageRootURL else { return nil }
        let rootPath = packageRootURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return String(path.dropFirst(rootPath.count + 1))
    }

}


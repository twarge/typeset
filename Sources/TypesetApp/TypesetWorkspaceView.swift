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

private func typesetLSPDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    guard UserDefaults.standard.bool(forKey: "developer.lspDebugLogging") else { return }
    print("[Typeset LSP UI] \(message())")
    #endif
}

private func typesetDropDebug(_ message: @autoclosure () -> String) {
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
                openedFileURL: fileURL
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

        // Self-write echo / no genuine change.
        guard diskHashes != diskFileSnapshot || diskFolders != diskFolderSnapshot else { return }

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

        syncLanguageServiceWorkspace()
        refreshPreview()
    }

    private func resolveConflictKeepingMine(_ conflict: DiskConflict) {
        // Idempotent: a button tap and the alert's dismiss-binding can both fire.
        guard pendingConflict?.id == conflict.id else { return }
        pendingConflict = nil
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

enum WorkspaceViewMode: String {
    case source
    case preview
    case both
}

/// An unresolved conflict: the open file was changed on disk by another program
/// while it had unsaved in-app edits. Drives the overwrite/revert prompt.
struct DiskConflict: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let diskText: String

    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

enum SplitBehavior: String, CaseIterable, Identifiable {
    case automatic
    case sideBySide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .sideBySide:
            return "Side by Side"
        case .stacked:
            return "Stacked"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic:
            return "rectangle.split.2x1"
        case .sideBySide:
            return "rectangle.split.2x1"
        case .stacked:
            return "rectangle.split.1x2"
        }
    }
}

enum SplitOrientation: Hashable {
    case horizontal
    case vertical
}

private enum FindDirection {
    case next
    case previous
}

private struct PendingEditorState: Equatable {
    var selectedFile: String
    var cursorLocation: Int
    var cursorLength: Int
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct WorkspaceSettingsPane: View {
    @Binding var themePreference: ThemePreference
    @Binding var splitBehavior: SplitBehavior
    @Binding var tallSplitThreshold: Double
    @Binding var imageInsertTemplate: String
    @Binding var figureInsertTemplate: String
    @Binding var tableInsertTemplate: String
    @Binding var showLineNumbers: Bool
    @Binding var spellCheckingEnabled: Bool
    @Binding var spellCheckingIgnoresCommands: Bool
    @Binding var autoExportPDFOnClose: Bool
    @Binding var updateReferencesOnRename: Bool
    @Binding var previewRenderWarmupDelay: Double
    @Binding var lspDebugLoggingEnabled: Bool
    // Shares the editor's persisted font-size key, so this control and any
    // open editor stay in sync.
    @AppStorage("sourceEditor.fontSize") private var editorFontSize = SourceEditorFont.defaultSize
    var onDismiss: () -> Void

    var body: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView {
                settingsContent
                    .padding(20)
                    .frame(maxWidth: 520, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #else
        VStack(spacing: 0) {
            ScrollView {
                settingsContent
                    .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 560)
        #endif
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if os(macOS)
            HStack(spacing: 10) {
                Image(systemName: "gearshape")
                Text("Settings")
                    .font(.headline)
            }
            #endif

            #if os(macOS)
            // Theme and split-orientation controls are macOS-only. iOS follows
            // the system appearance and always shows panes side by side.
            VStack(alignment: .leading, spacing: 10) {
                Text("Theme")
                    .font(.subheadline.weight(.semibold))

                Picker("Theme", selection: $themePreference) {
                    ForEach(ThemePreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Split Layout")
                    .font(.subheadline.weight(.semibold))

                Picker("Split Layout", selection: $splitBehavior) {
                    ForEach(SplitBehavior.allCases) { behavior in
                        Label(behavior.title, systemImage: behavior.symbolName)
                            .tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tall Window Threshold")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(tallSplitThreshold, format: .number.precision(.fractionLength(2)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $tallSplitThreshold, in: 0.8...1.8, step: 0.02)
                    .disabled(splitBehavior != .automatic)
            }
            .opacity(splitBehavior == .automatic ? 1 : 0.45)
            #endif

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Editor Font Size")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(editorFontSize.rounded())) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: $editorFontSize,
                    in: SourceEditorFont.minimumSize...SourceEditorFont.maximumSize,
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Image Insert Template")
                    .font(.subheadline.weight(.semibold))

                TextField(SourceEditorDropSnippet.defaultImageTemplate, text: $imageInsertTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Text("Use {path} for the dragged file path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Figure Insert Template")
                    .font(.subheadline.weight(.semibold))

                TextField(SourceEditorDropSnippet.defaultFigureTemplate, text: $figureInsertTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...6)

                Text("Inserted with ⌥⌘F. Use {cursor} to place the caret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Table Insert Template")
                    .font(.subheadline.weight(.semibold))

                TextField(SourceEditorDropSnippet.defaultTableTemplate, text: $tableInsertTemplate, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...6)

                Text("Inserted with ⌥⌘T. Use {cursor} to place the caret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Editor")
                    .font(.subheadline.weight(.semibold))

                Toggle("Show Line Numbers", isOn: $showLineNumbers)
                Toggle("Check Spelling in Prose", isOn: $spellCheckingEnabled)
                Toggle("Ignore Typst Commands and Arguments", isOn: $spellCheckingIgnoresCommands)
                    .disabled(!spellCheckingEnabled)
                Toggle("Update References When Renaming or Moving Files", isOn: $updateReferencesOnRename)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Preview Buffer Delay")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(previewRenderWarmupDelay, specifier: "%.2f")s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $previewRenderWarmupDelay, in: 0...1, step: 0.05)
            }

            #if os(macOS)
            VStack(alignment: .leading, spacing: 10) {
                Text("Export")
                    .font(.subheadline.weight(.semibold))

                Toggle("Export PDF on Close", isOn: $autoExportPDFOnClose)
            }
            #endif

            VStack(alignment: .leading, spacing: 10) {
                Text("Developer")
                    .font(.subheadline.weight(.semibold))

                Toggle("Log LSP Requests", isOn: $lspDebugLoggingEnabled)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Typeset is made by Twarge LLC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Link("hello@twarge.com", destination: URL(string: "mailto:hello@twarge.com")!)
                    .font(.footnote)
            }
        }
    }
}

struct FindReplacePanel: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var isCaseSensitive: Bool
    var currentIndex: Int?
    var matchCount: Int
    var onFindChanged: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field {
        case find
        case replace
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .find)
                    .onSubmit(onNext)
                    .onChange(of: findText) { _, _ in
                        onFindChanged()
                    }

                Text(matchStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Button(action: onPrevious) {
                    Label("Previous", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                .help("Previous Match")
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Label("Next", systemImage: "chevron.down")
                }
                .labelStyle(.iconOnly)
                .help("Next Match")
                .disabled(matchCount == 0)

                Button(action: onClose) {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .help("Close")
            }

            HStack(spacing: 8) {
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .replace)
                    .onSubmit(onReplace)

                Toggle(isOn: $isCaseSensitive) {
                    Text("Aa")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .help("Match Case")
                .onChange(of: isCaseSensitive) { _, _ in
                    onFindChanged()
                }

                Button("Replace", action: onReplace)
                    .disabled(matchCount == 0)

                Button("All", action: onReplaceAll)
                    .disabled(matchCount == 0)
            }
        }
        .padding(10)
        .frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
        .onAppear {
            focusedField = .find
            onFindChanged()
        }
    }

    private var matchStatus: String {
        guard !findText.isEmpty else { return "" }
        guard matchCount > 0 else { return "0" }
        if let currentIndex {
            return "\(currentIndex)/\(matchCount)"
        }
        return "\(matchCount)"
    }
}

struct StableSourcePane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct ToolbarStatusIcon: View {
    var isLogPresented: Bool
    var isCompiling: Bool
    var hasErrorLogs: Bool

    var body: some View {
        Group {
            if isLogPresented {
                Image(systemName: "xmark")
            } else if isCompiling {
                // Stop icon: keep it a plain image so the button stays part of
                // the unified toolbar group (a ProgressView renders as a bare,
                // unbordered item that visually splits the group). Tapping it
                // cancels the compile.
                Image(systemName: "stop.fill")
            } else if hasErrorLogs {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                // Run icon: the preview is up to date; tapping recompiles.
                Image(systemName: "play.fill")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isLogPresented)
        .animation(.easeInOut(duration: 0.15), value: isCompiling)
        .animation(.easeInOut(duration: 0.15), value: hasErrorLogs)
    }
}

struct PackageAssetPreview: View {
    var file: PackageFile

    @State private var previewURL: URL?
    @State private var previewError: String?

    var body: some View {
        Group {
            if file.isImageAsset {
                PackageImagePreview(file: file)
            } else if let previewURL {
                PlatformQuickLookPreview(url: previewURL)
                    .background(.background)
            } else if let previewError {
                ContentUnavailableView(file.name, systemImage: "exclamationmark.triangle", description: Text(previewError))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: previewIdentity) {
            if file.isImageAsset {
                previewURL = nil
                previewError = nil
            } else {
                preparePreviewFile()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewIdentity: String {
        "\(file.path)-\(file.data.count)-\(file.data.hashValue)"
    }

    private func preparePreviewFile() {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "TypesetAssetPreviews", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            try file.data.write(to: url, options: .atomic)
            previewURL = url
            previewError = nil
        } catch {
            previewURL = nil
            previewError = error.localizedDescription
        }
    }
}

struct PackageImagePreview: View {
    var file: PackageFile
    var backgroundColor = Color.clear

    var body: some View {
        Group {
            if file.isPDF {
                if PDFDocument(data: file.data) != nil {
                    PackagePDFView(data: file.data)
                        .background(backgroundColor)
                } else {
                    ContentUnavailableView(file.name, systemImage: "doc.richtext", description: Text("The PDF could not be displayed."))
                }
            } else if let image = PlatformImage(data: file.data) {
                GeometryReader { proxy in
                    PlatformImageView(image: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .background(backgroundColor)
            } else {
                ContentUnavailableView(file.name, systemImage: "photo", description: Text("The image could not be displayed."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
private typealias PlatformImage = NSImage

private func PlatformImageView(image: PlatformImage) -> Image {
    Image(nsImage: image)
}

struct PlatformQuickLookPreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}

/// Renders PDF data with PDFKit's scrollable, zoomable `PDFView`. The document
/// is rebuilt only when the underlying data changes, so scroll/zoom isn't reset
/// on unrelated re-renders.
struct PackagePDFView: NSViewRepresentable {
    var data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .white
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
#else
private typealias PlatformImage = UIImage

private func PlatformImageView(image: PlatformImage) -> Image {
    Image(uiImage: image)
}

struct PlatformQuickLookPreview: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// Renders PDF data with PDFKit's scrollable, zoomable `PDFView`. The document
/// is rebuilt only when the underlying data changes, so scroll/zoom isn't reset
/// on unrelated re-renders.
struct PackagePDFView: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .white
        view.document = PDFDocument(data: data)
        context.coordinator.data = data
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var data: Data? }
}
#endif

private extension PackageFile {
    private var fileType: UTType? {
        guard let fileExtension = name.split(separator: ".").last,
              fileExtension != name else {
            return nil
        }
        return UTType(filenameExtension: String(fileExtension))
    }

    var isImageAsset: Bool {
        fileType?.conforms(to: .image) ?? false
    }

    var isPDF: Bool {
        fileType?.conforms(to: .pdf) ?? false
    }

    /// Files shown in the sidebar's image/PDF popover rather than opened in the
    /// editor or the main asset preview.
    var isPopoverPreviewable: Bool {
        isImageAsset || isPDF
    }

    var isPythonScript: Bool {
        path.lowercased().hasSuffix(".py")
    }
}

private extension View {
    @ViewBuilder
    func platformPreferredColorScheme(_ colorScheme: ColorScheme?) -> some View {
        #if os(macOS)
        self
        #else
        self.preferredColorScheme(colorScheme)
        #endif
    }

    @ViewBuilder
    func platformTransparentToolbarBackground() -> some View {
        #if os(macOS)
        self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }
}

struct DiagnosticLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info
        case warning
        case error
    }

    var id = UUID()
    var date = Date()
    var title: String
    var message: String
    var level: Level
    var diagnostic: TypstSourceDiagnostic? = nil

    var isError: Bool {
        level == .error
    }
}

#if os(iOS)
private struct PDFShareItem: Identifiable {
    let id = UUID()
    var url: URL
}

private struct PDFShareSheet: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct DiagnosticLogSlideOver: View {
    var entries: [DiagnosticLogEntry]
    var isPresented: Bool
    var onSelectDiagnostic: (TypstSourceDiagnostic) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if isPresented {
                    panel
                        .frame(width: min(max(proxy.size.width * 0.36, 320), 460))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isPresented)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Logs", systemImage: "list.bullet.rectangle")
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .opacity(0.45)

            if entries.isEmpty {
                ContentUnavailableView("No Logs", systemImage: "checkmark.circle", description: Text("Compilation messages will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            DiagnosticLogRow(entry: entry, onSelectDiagnostic: onSelectDiagnostic)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, x: -12, y: 0)
        .ignoresSafeArea(.container, edges: [.bottom, .trailing])
    }
}

struct DiagnosticLogRow: View {
    var entry: DiagnosticLogEntry
    var onSelectDiagnostic: (TypstSourceDiagnostic) -> Void = { _ in }

    var body: some View {
        Button {
            if let diagnostic = entry.diagnostic {
                onSelectDiagnostic(diagnostic)
            }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(entry.diagnostic == nil)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)

                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(entry.date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.26), lineWidth: 1)
        }
    }

    private var icon: String {
        switch entry.level {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.octagon"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var rowBackground: some ShapeStyle {
        color.opacity(0.11)
    }
}

// MARK: - Find in Files

/// One occurrence of the search query in a file, with the surrounding line text
/// split around the match for inline highlighting.
struct FileSearchMatch: Identifiable, Equatable {
    let id: Int            // the match's UTF-16 location (stable within a file)
    let range: NSRange     // the match's range within the file's text
    let lineNumber: Int    // 1-based
    let linePrefix: String
    let matchText: String
    let lineSuffix: String
}

/// All matches within a single file.
struct FileSearchResult: Identifiable, Equatable {
    let id: String         // file path
    let path: String
    let name: String
    let matches: [FileSearchMatch]
    /// True when the file had more matches than `maxMatchesPerFile`, so the
    /// listed matches are only the first page. (Replace All still replaces every
    /// occurrence — see `matchSummary`, which shows "N+".)
    let isTruncated: Bool
}

enum FileTextSearch {
    /// Bounds work per file so an enormous accidental match set (e.g. searching a
    /// single space) can't stall the UI.
    static let maxMatchesPerFile = 1000

    static func results(in files: [PackageFile], query: String, isCaseSensitive: Bool) -> [FileSearchResult] {
        guard !query.isEmpty else { return [] }
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var output: [FileSearchResult] = []
        for file in files where file.isTextEditable {
            let nsText = String(decoding: file.data, as: UTF8.self) as NSString
            guard nsText.length > 0 else { continue }
            var matches: [FileSearchMatch] = []
            var isTruncated = false
            var searchStart = 0
            var lineNumber = 1
            var scannedForLines = 0
            while searchStart < nsText.length {
                let found = nsText.range(
                    of: query,
                    options: options,
                    range: NSRange(location: searchStart, length: nsText.length - searchStart)
                )
                if found.location == NSNotFound { break }
                // Cap reached and yet another match exists -> genuinely truncated.
                if matches.count >= maxMatchesPerFile { isTruncated = true; break }
                if found.location > scannedForLines {
                    lineNumber += newlineCount(in: nsText, from: scannedForLines, to: found.location)
                    scannedForLines = found.location
                }
                let lineRange = nsText.lineRange(for: NSRange(location: found.location, length: 0))
                let prefix = nsText.substring(with: NSRange(location: lineRange.location, length: found.location - lineRange.location))
                let suffixStart = NSMaxRange(found)
                let suffixLength = max(0, NSMaxRange(lineRange) - suffixStart)
                let suffix = nsText.substring(with: NSRange(location: suffixStart, length: suffixLength))
                matches.append(FileSearchMatch(
                    id: found.location,
                    range: found,
                    lineNumber: lineNumber,
                    linePrefix: displaySnippet(prefix, keepingTail: true),
                    matchText: nsText.substring(with: found),
                    lineSuffix: displaySnippet(suffix, keepingTail: false)
                ))
                searchStart = found.location + max(1, found.length)
            }
            if !matches.isEmpty {
                output.append(FileSearchResult(id: file.path, path: file.path, name: file.name, matches: matches, isTruncated: isTruncated))
            }
        }
        return output
    }

    private static func newlineCount(in text: NSString, from start: Int, to end: Int) -> Int {
        var count = 0
        var index = start
        while index < end {
            let r = text.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            if r.location == NSNotFound { break }
            count += 1
            index = r.location + 1
        }
        return count
    }

    /// Trims a line fragment to a compact single line, clipping the end away from
    /// the match and collapsing indentation/tabs so the match stays visible.
    private static func displaySnippet(_ raw: String, keepingTail: Bool) -> String {
        var collapsed = raw
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if keepingTail {
            while collapsed.first == " " { collapsed.removeFirst() }
        }
        let limit = 80
        guard collapsed.count > limit else { return collapsed }
        return keepingTail ? "…" + String(collapsed.suffix(limit)) : String(collapsed.prefix(limit)) + "…"
    }
}

/// The Find-in-Files sidebar tab: searches every text file, lists matches
/// grouped by file, and supports replacing a single match or all of them.
struct WorkspaceSearchView: View {
    var files: [PackageFile]
    @Binding var query: String
    @Binding var replacement: String
    @Binding var isCaseSensitive: Bool
    @Binding var isReplaceVisible: Bool
    /// One-shot: when true, focus the search field and reset it. Set by ⌘⇧F.
    @Binding var activation: Bool
    var onSelectMatch: (String, NSRange) -> Void
    var onReplaceMatch: (String, NSRange, String, String, Bool) -> Void
    var onReplaceAll: (String, String, Bool) -> Void

    @FocusState private var isQueryFocused: Bool

    var body: some View {
        // Compute the search exactly once per body evaluation and thread it
        // through; recomputing inside several computed properties ran the whole
        // multi-file scan 4-5x per keystroke.
        let results = FileTextSearch.results(in: files, query: query, isCaseSensitive: isCaseSensitive)
        let totalMatches = results.reduce(0) { $0 + $1.matches.count }
        return VStack(spacing: 0) {
            controls(totalMatches: totalMatches)
            Divider()
            content(results: results, totalMatches: totalMatches)
        }
        .onAppear { consumeActivationIfNeeded() }
        .onChange(of: activation) { _, _ in consumeActivationIfNeeded() }
    }

    /// Focuses the field only when the user explicitly invoked Find (⌘⇧F), then
    /// clears the flag — so restoring the Find tab on launch never steals focus
    /// from the editor.
    private func consumeActivationIfNeeded() {
        guard activation else { return }
        DispatchQueue.main.async {
            isQueryFocused = true
            activation = false
        }
    }

    private func controls(totalMatches: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in files", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isQueryFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { isQueryFocused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button { isCaseSensitive.toggle() } label: {
                    Text("Aa").fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCaseSensitive ? Color.accentColor : Color.secondary)
                .help("Match case")

                Button {
                    withAnimation(.snappy(duration: 0.15)) { isReplaceVisible.toggle() }
                } label: {
                    Image(systemName: isReplaceVisible ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Toggle replace")
            }

            if isReplaceVisible {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                    TextField("Replace", text: $replacement)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("All") {
                        onReplaceAll(query, replacement, isCaseSensitive)
                    }
                    .disabled(query.isEmpty || totalMatches == 0)
                    .help("Replace every match")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(results: [FileSearchResult], totalMatches: Int) -> some View {
        if query.isEmpty {
            emptyState(title: "Find in Files", message: "Search the text of every file in this document.", systemImage: "magnifyingglass")
        } else if results.isEmpty {
            emptyState(title: "No Matches", message: "No file contains the search text.", systemImage: "magnifyingglass")
        } else {
            List {
                Text(matchSummary(results: results, totalMatches: totalMatches))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(results) { result in
                    Section(result.name) {
                        ForEach(result.matches) { match in
                            matchRow(result: result, match: match)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func matchSummary(results: [FileSearchResult], totalMatches: Int) -> String {
        let truncated = results.contains { $0.isTruncated }
        let count = truncated ? "\(totalMatches)+" : "\(totalMatches)"
        let fileWord = results.count == 1 ? "file" : "files"
        let matchWord = totalMatches == 1 ? "match" : "matches"
        return "\(count) \(matchWord) in \(results.count) \(fileWord)"
    }

    private func matchRow(result: FileSearchResult, match: FileSearchMatch) -> some View {
        Button {
            onSelectMatch(result.path, match.range)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(match.lineNumber)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                let linePrefix = Text(match.linePrefix).foregroundColor(.secondary)
                let highlightedMatch = Text(match.matchText).foregroundColor(.primary).bold()
                let lineSuffix = Text(match.lineSuffix).foregroundColor(.secondary)
                Text("\(linePrefix)\(highlightedMatch)\(lineSuffix)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal") {
                onSelectMatch(result.path, match.range)
            }
            Button("Replace") {
                onReplaceMatch(result.path, match.range, replacement, query, isCaseSensitive)
            }
        }
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(.tertiary)
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum FileTreeEditingTarget: Equatable {
    case file(String)
    case folder(String)
}

struct FileSidebar: View {
    var files: [PackageFile]
    var folders: [String]
    var selectedPath: String
    var selectedFolderPath: String?
    var packageFilePaths: Set<String>
    var packageFolderPaths: Set<String>
    var compileTargetPath: String
    var canSetCompileTarget: Bool
    var expandedFolders: Set<String>
    var documentSymbols: TypstDocumentSymbols
    var restoredSidebarTabRawValue: String
    @Binding var findActivation: Bool
    @Binding var pendingEdit: FileTreeEditingTarget?
    var onSidebarTabChange: (String) -> Void
    var onSelectSymbolRange: (NSRange) -> Void
    var onSearchSelectMatch: (String, NSRange) -> Void
    var onSearchReplaceMatch: (String, NSRange, String, String, Bool) -> Void
    var onSearchReplaceAll: (String, String, Bool) -> Void
    var onNewFile: () -> Void
    var onNewFolder: () -> Void
    var onImportFromPicker: () -> Void
    var onSelectFile: (String) -> Void
    var onSelectFolder: (String) -> Void
    var onExpandedFoldersChange: (Set<String>) -> Void
    var onMoveFile: (String, String?) -> Void
    var onMoveFolder: (String, String?) -> Void
    var onImportFiles: ([URL], String?, Bool) -> Void
    var onImportPhotos: ([PhotosPickerItem]) -> Void
    var onRenameFile: (String, String) -> Void
    var onRenameFolder: (String, String) -> Void
    var onDeleteFile: (String) -> Void
    var onDuplicateFile: (String) -> Void
    var onDeleteFolder: (String) -> Void
    var onSetCompileTarget: (String) -> Void
    var onRunPythonScript: (String) -> Void
    var onError: (String, String) -> Void

    @State private var editingTarget: FileTreeEditingTarget?
    @State private var editingName = ""
    @State private var highlightedDropFolder: String?
    @State private var isRootDropTargeted = false
    @State private var renameClickTarget: FileTreeSelection?
    @State private var renameClickDate = Date.distantPast
    @State private var sidebarTab: SidebarTab = .files
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var searchQuery = ""
    @State private var searchReplacement = ""
    @State private var searchIsCaseSensitive = false
    @State private var searchIsReplaceVisible = false

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case files
        case outline
        case figures
        case references
        case search

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files: return "Files"
            case .outline: return "Outline"
            case .figures: return "Figures"
            case .references: return "Refs"
            case .search: return "Find"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabSelector

            switch sidebarTab {
            case .files:
                sidebarToolbar
                fileList
            case .outline:
                outlineList
            case .figures:
                figuresList
            case .references:
                referencesList
            case .search:
                searchTab
            }
        }
        .platformSidebarColumnBackground()
        .onAppear {
            consumePendingEdit()
            // A pending Find activation wins over the restored tab. Checking it
            // in `onAppear` (not only `onChange`) is what makes ⌘⇧F work on iOS,
            // where the sidebar is re-created on each open and `onChange` can't
            // fire on the fresh mount.
            if findActivation {
                sidebarTab = .search
            } else if let restored = SidebarTab(rawValue: restoredSidebarTabRawValue) {
                sidebarTab = restored
            }
        }
        .onChange(of: pendingEdit) { _, _ in
            consumePendingEdit()
        }
        .onChange(of: sidebarTab) { _, newValue in
            onSidebarTabChange(newValue.rawValue)
        }
        .onChange(of: findActivation) { _, isPending in
            if isPending { sidebarTab = .search }
        }
    }

    @ViewBuilder
    private var searchTab: some View {
        WorkspaceSearchView(
            files: files,
            query: $searchQuery,
            replacement: $searchReplacement,
            isCaseSensitive: $searchIsCaseSensitive,
            isReplaceVisible: $searchIsReplaceVisible,
            activation: $findActivation,
            onSelectMatch: onSearchSelectMatch,
            onReplaceMatch: onSearchReplaceMatch,
            onReplaceAll: onSearchReplaceAll
        )
    }

    private var tabSelector: some View {
        Picker("Sidebar View", selection: $sidebarTab) {
            ForEach(SidebarTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, sidebarToolbarHorizontalPadding)
        .padding(.vertical, sidebarToolbarVerticalPadding)
        .platformSidebarToolbarBackground()
    }

    @ViewBuilder
    private var outlineList: some View {
        if documentSymbols.outline.isEmpty {
            sidebarEmptyState(
                title: "No Headings",
                message: "Add headings with =, ==, … to build an outline.",
                systemImage: "list.bullet.indent"
            )
        } else {
            List {
                ForEach(documentSymbols.outline) { item in
                    Button {
                        onSelectSymbolRange(item.range)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.level <= 1 ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                                .foregroundStyle(.secondary)
                            Text(item.title.isEmpty ? "Untitled" : item.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.leading, CGFloat(max(0, item.level - 1)) * 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var figuresList: some View {
        if documentSymbols.figures.isEmpty {
            sidebarEmptyState(
                title: "No Figures or Tables",
                message: "Add a #figure(…) or #table(…) to list it here.",
                systemImage: "photo.on.rectangle.angled"
            )
        } else {
            List {
                ForEach(documentSymbols.figures) { item in
                    Button {
                        onSelectSymbolRange(item.range)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.kind == .table ? "tablecells" : "photo")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title.isEmpty ? item.kind.rawValue.capitalized : item.title)
                                    .lineLimit(1)
                                if !item.label.isEmpty {
                                    Text(item.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var referencesList: some View {
        if documentSymbols.references.isEmpty {
            sidebarEmptyState(
                title: "No References",
                message: "Define a <label> and reference it with @label.",
                systemImage: "link"
            )
        } else {
            List {
                ForEach(documentSymbols.references) { group in
                    // The referenced element (the <label> definition).
                    Button {
                        if let source = group.source {
                            onSelectSymbolRange(source)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: group.source != nil ? "tag" : "exclamationmark.triangle.fill")
                                .foregroundStyle(group.source != nil ? Color.secondary : Color.orange)
                            Text(group.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text("\(group.uses.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(group.source == nil)

                    // A sublist of every place the label is used (@label).
                    ForEach(group.uses) { use in
                        Button {
                            onSelectSymbolRange(use.range)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .foregroundStyle(.tertiary)
                                Text("@\(group.name)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func sidebarEmptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(.tertiary)
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarToolbar: some View {
        HStack(spacing: sidebarToolbarSpacing) {
            Button(action: onNewFile) {
                Label("New File", systemImage: "doc.badge.plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: sidebarToolbarButtonSize, height: sidebarToolbarButtonSize)
            .contentShape(Rectangle())
            .help("New File")

            Button(action: onNewFolder) {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: sidebarToolbarButtonSize, height: sidebarToolbarButtonSize)
            .contentShape(Rectangle())
            .help("New Folder")

            Button(action: onImportFromPicker) {
                Label("Import Files", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: sidebarToolbarButtonSize, height: sidebarToolbarButtonSize)
            .contentShape(Rectangle())
            .help("Import Files")

            PhotosPicker(
                selection: $selectedPhotoItems,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Add Photo", systemImage: "photo.badge.plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: sidebarToolbarButtonSize, height: sidebarToolbarButtonSize)
            .contentShape(Rectangle())
            .help("Add Photo")
            .onChange(of: selectedPhotoItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                onImportPhotos(newItems)
                selectedPhotoItems = []
            }

            Spacer(minLength: 0)
        }
        .font(sidebarToolbarFont)
        .padding(.horizontal, sidebarToolbarHorizontalPadding)
        .padding(.vertical, sidebarToolbarVerticalPadding)
        .platformSidebarToolbarBackground()
        .overlay(alignment: .bottom) { Divider() }
    }

    private var sidebarToolbarSpacing: CGFloat {
        #if os(iOS)
        8
        #else
        6
        #endif
    }

    private var sidebarToolbarButtonSize: CGFloat {
        #if os(iOS)
        44
        #else
        24
        #endif
    }

    private var sidebarToolbarHorizontalPadding: CGFloat {
        #if os(iOS)
        12
        #else
        10
        #endif
    }

    private var sidebarToolbarVerticalPadding: CGFloat {
        #if os(iOS)
        8
        #else
        6
        #endif
    }

    private var sidebarToolbarFont: Font {
        #if os(iOS)
        .title3
        #else
        .body
        #endif
    }

    @ViewBuilder
    private var fileList: some View {
        #if os(iOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                fileTreeRows
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .overlay {
            rootDropHighlight
        }
        .onDrop(
            of: PackageDropDelegate.supportedTypes,
                delegate: PackageDropDelegate(
                    destinationFolder: nil,
                    packageFilePaths: visiblePackageFilePaths,
                    packageFolderPaths: visiblePackageFolderPaths,
                    onMoveFile: onMoveFile,
                    onMoveFolder: onMoveFolder,
                    onImportFiles: onImportFiles,
                onError: onError,
                onTargetedChanged: { isRootDropTargeted = $0 }
            )
        )
        #else
        List {
            fileTreeRows
        }
        .listStyle(.sidebar)
        .overlay {
            rootDropHighlight
        }
        .onDrop(
            of: PackageDropDelegate.supportedTypes,
                delegate: PackageDropDelegate(
                    destinationFolder: nil,
                    packageFilePaths: visiblePackageFilePaths,
                    packageFolderPaths: visiblePackageFolderPaths,
                    onMoveFile: onMoveFile,
                    onMoveFolder: onMoveFolder,
                    onImportFiles: onImportFiles,
                onError: onError,
                onTargetedChanged: { isRootDropTargeted = $0 }
            )
        )
        #endif
    }

    private var fileTreeNodes: [FileTreeNode] {
        FileTreeNode.roots(files: visibleFiles, folders: visibleFolders, compileTargetPath: compileTargetPath)
    }

    private var visibleFiles: [PackageFile] {
        files.filter { !isHiddenPackagePath($0.path) }
    }

    private var visibleFolders: [String] {
        folders.filter { !isHiddenPackagePath($0) }
    }

    private var visiblePackageFilePaths: Set<String> {
        Set(visibleFiles.map(\.path))
    }

    private var visiblePackageFolderPaths: Set<String> {
        Set(visibleFolders)
    }

    @ViewBuilder
    private var fileTreeRows: some View {
        ForEach(fileTreeNodes) { node in
            FileTreeRow(
                node: node,
                depth: 0,
                selectedPath: selectedPath,
                selectedFolderPath: selectedFolderPath,
                packageFilePaths: visiblePackageFilePaths,
                packageFolderPaths: visiblePackageFolderPaths,
                compileTargetPath: compileTargetPath,
                canSetCompileTarget: canSetCompileTarget,
                expandedFolders: expandedFolders,
                editingTarget: $editingTarget,
                editingName: $editingName,
                highlightedDropFolder: $highlightedDropFolder,
                renameClickTarget: $renameClickTarget,
                renameClickDate: $renameClickDate,
                onSelect: select,
                onExpandedFoldersChange: onExpandedFoldersChange,
                onBeginRename: beginRename,
                onBeginRenameFolder: beginRenameFolder,
                onCommitRename: commitRename,
                onCommitRenameFolder: commitRenameFolder,
                onMoveFile: onMoveFile,
                onMoveFolder: onMoveFolder,
                onImportFiles: onImportFiles,
                onSetCompileTarget: onSetCompileTarget,
                onDeleteFile: onDeleteFile,
                onDuplicateFile: onDuplicateFile,
                onDeleteFolder: onDeleteFolder,
                onRunPythonScript: onRunPythonScript,
                onError: onError
            )
        }
    }

    private var rootDropHighlight: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.tint.opacity(isRootDropTargeted ? 0.55 : 0), lineWidth: 2)
            .background(.tint.opacity(isRootDropTargeted ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 8))
            .padding(4)
            .animation(.snappy(duration: 0.18), value: isRootDropTargeted)
            .allowsHitTesting(false)
    }

    private func select(_ selection: FileTreeSelection) {
        switch selection {
        case .file(let path):
            onSelectFile(path)
        case .folder(let path):
            onSelectFolder(path)
        }
    }

    private func beginRename(_ file: PackageFile) {
        editingTarget = .file(file.path)
        editingName = file.name
    }

    private func beginRenameFolder(path: String, name: String) {
        editingTarget = .folder(path)
        editingName = name
    }

    private func beginRename(_ target: FileTreeEditingTarget) {
        editingTarget = target
        switch target {
        case .file(let path), .folder(let path):
            editingName = URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func consumePendingEdit() {
        guard let pendingEdit else { return }
        beginRename(pendingEdit)
        DispatchQueue.main.async {
            self.pendingEdit = nil
        }
    }

    private func commitRename(_ file: PackageFile) {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTarget = nil
        editingName = ""

        guard !name.isEmpty, name != file.name else { return }
        onRenameFile(file.path, name)
    }

    private func commitRenameFolder(path: String, currentName: String) {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTarget = nil
        editingName = ""

        guard !name.isEmpty, name != currentName else { return }
        onRenameFolder(path, name)
    }
}

struct FileTreeRow: View {
    var node: FileTreeNode
    var depth: Int
    var selectedPath: String
    var selectedFolderPath: String?
    var packageFilePaths: Set<String>
    var packageFolderPaths: Set<String>
    var compileTargetPath: String
    var canSetCompileTarget: Bool
    var expandedFolders: Set<String>
    @Binding var editingTarget: FileTreeEditingTarget?
    @Binding var editingName: String
    @Binding var highlightedDropFolder: String?
    @Binding var renameClickTarget: FileTreeSelection?
    @Binding var renameClickDate: Date
    var onSelect: (FileTreeSelection) -> Void
    var onExpandedFoldersChange: (Set<String>) -> Void
    var onBeginRename: (PackageFile) -> Void
    var onBeginRenameFolder: (String, String) -> Void
    var onCommitRename: (PackageFile) -> Void
    var onCommitRenameFolder: (String, String) -> Void
    var onMoveFile: (String, String?) -> Void
    var onMoveFolder: (String, String?) -> Void
    var onImportFiles: ([URL], String?, Bool) -> Void
    var onSetCompileTarget: (String) -> Void
    var onDeleteFile: (String) -> Void
    var onDuplicateFile: (String) -> Void
    var onDeleteFolder: (String) -> Void
    var onRunPythonScript: (String) -> Void
    var onError: (String, String) -> Void

    @State private var previewedImageFile: PackageFile?

    var body: some View {
        switch node.kind {
        case .folder:
            #if os(iOS)
            VStack(alignment: .leading, spacing: 0) {
                iosFolderHeader
                if expandedFolders.contains(node.path) {
                    folderChildren
                }
            }
            .animation(.snappy(duration: 0.18), value: isDropTargetedFolder)
            .animation(.snappy(duration: 0.18), value: expandedFolders.contains(node.path))
            #else
            DisclosureGroup(isExpanded: folderExpansionBinding) {
                folderChildren
            } label: {
                folderLabel
            }
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.clear)
            }
            #if os(macOS)
            .listRowBackground(folderRowBackground)
            #endif
            .animation(.snappy(duration: 0.18), value: isDropTargetedFolder)
            #endif
        case .file(let file):
            fileRow(for: file)
        }
    }

    @ViewBuilder
    private var folderChildren: some View {
        ForEach(node.children) { child in
            FileTreeRow(
                node: child,
                depth: depth + 1,
                selectedPath: selectedPath,
                selectedFolderPath: selectedFolderPath,
                packageFilePaths: packageFilePaths,
                packageFolderPaths: packageFolderPaths,
                compileTargetPath: compileTargetPath,
                canSetCompileTarget: canSetCompileTarget,
                expandedFolders: expandedFolders,
                editingTarget: $editingTarget,
                editingName: $editingName,
                highlightedDropFolder: $highlightedDropFolder,
                renameClickTarget: $renameClickTarget,
                renameClickDate: $renameClickDate,
                onSelect: onSelect,
                onExpandedFoldersChange: onExpandedFoldersChange,
                onBeginRename: onBeginRename,
                onBeginRenameFolder: onBeginRenameFolder,
                onCommitRename: onCommitRename,
                onCommitRenameFolder: onCommitRenameFolder,
                onMoveFile: onMoveFile,
                onMoveFolder: onMoveFolder,
                onImportFiles: onImportFiles,
                onSetCompileTarget: onSetCompileTarget,
                onDeleteFile: onDeleteFile,
                onDuplicateFile: onDuplicateFile,
                onDeleteFolder: onDeleteFolder,
                onRunPythonScript: onRunPythonScript,
                onError: onError
            )
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var iosFolderHeader: some View {
        if editingTarget == .folder(node.path) {
            HStack(spacing: 6) {
                folderDisclosureButton

                FileRenameField(
                    name: $editingName,
                    systemImage: "folder",
                    onCommit: {
                        onCommitRenameFolder(node.path, node.name)
                    },
                    onCancel: {
                        editingTarget = nil
                        editingName = ""
                    }
                )
            }
            .sidebarRowInsets(depth: depth)
            .iosSidebarRowBackground {
                folderRowBackground
            }
        } else {
            HStack(spacing: 6) {
                folderDisclosureButton

                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sidebarRowInsets(depth: depth)
            .iosSidebarRowBackground {
                folderRowBackground
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let selection = FileTreeSelection.folder(node.path)
                onSelect(selection)
            }
            .contextMenu {
                Button("Rename") {
                    onBeginRenameFolder(node.path, node.name)
                }
                Button("Delete", role: .destructive) {
                    onDeleteFolder(node.path)
                }
            }
            .onDrop(
                of: PackageDropDelegate.supportedTypes,
                delegate: PackageDropDelegate(
                    destinationFolder: node.path,
                    packageFilePaths: packageFilePaths,
                    packageFolderPaths: packageFolderPaths,
                    onMoveFile: onMoveFile,
                    onMoveFolder: onMoveFolder,
                    onImportFiles: onImportFiles,
                    onError: onError,
                    onTargetedChanged: { isTargeted in
                        highlightedDropFolder = isTargeted ? node.path : nil
                    }
                )
            )
            .draggable(PackageFolderDragItem(path: node.path, name: node.name)) {
                dragPreview(systemImage: "folder", name: node.name, isCompileTarget: false)
            }
        }
    }

    private var folderDisclosureButton: some View {
        Button {
            folderExpansionBinding.wrappedValue.toggle()
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expandedFolders.contains(node.path) ? 90 : 0))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expandedFolders.contains(node.path) ? "Collapse Folder" : "Expand Folder")
    }
    #endif

    @ViewBuilder
    private var folderLabel: some View {
        if editingTarget == .folder(node.path) {
            FileRenameField(
                name: $editingName,
                systemImage: "folder",
                onCommit: {
                    onCommitRenameFolder(node.path, node.name)
                },
                onCancel: {
                    editingTarget = nil
                    editingName = ""
                }
            )
            .sidebarRowInsets(depth: depth)
            .iosSidebarRowBackground {
                folderRowBackground
            }
        } else {
            Label(node.name, systemImage: "folder")
                .frame(maxWidth: .infinity, alignment: .leading)
                .sidebarRowInsets(depth: depth)
                .iosSidebarRowBackground {
                    folderRowBackground
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let selection = FileTreeSelection.folder(node.path)
                    if shouldBeginRename(for: selection, isCurrentSelection: selectedFolderPath == node.path) {
                        onBeginRenameFolder(node.path, node.name)
                    } else {
                        onSelect(selection)
                    }
                }
                .contextMenu {
                    Button("Rename") {
                        onBeginRenameFolder(node.path, node.name)
                    }
                    Button("Delete", role: .destructive) {
                        onDeleteFolder(node.path)
                    }
                }
                .onDrop(
                    of: PackageDropDelegate.supportedTypes,
                    delegate: PackageDropDelegate(
                        destinationFolder: node.path,
                        packageFilePaths: packageFilePaths,
                        packageFolderPaths: packageFolderPaths,
                        onMoveFile: onMoveFile,
                        onMoveFolder: onMoveFolder,
                        onImportFiles: onImportFiles,
                        onError: onError,
                        onTargetedChanged: { isTargeted in
                            highlightedDropFolder = isTargeted ? node.path : nil
                        }
                    )
                )
                // See the file row for why this is platform-split:
                // macOS needs `.onDrag` so the drag starts from the icon
                // and label too, not just the empty Spacer area.
                #if os(macOS)
                .onDrag {
                    FolderTreeDragPayload.itemProvider(path: node.path, name: node.name)
                } preview: {
                    dragPreview(systemImage: "folder", name: node.name, isCompileTarget: false)
                }
                #else
                .draggable(PackageFolderDragItem(path: node.path, name: node.name)) {
                    dragPreview(systemImage: "folder", name: node.name, isCompileTarget: false)
                }
                #endif
        }
    }

    private var folderExpansionBinding: Binding<Bool> {
        Binding {
            expandedFolders.contains(node.path)
        } set: { isExpanded in
            var next = expandedFolders
            if isExpanded {
                next.insert(node.path)
            } else {
                next.remove(node.path)
            }
            onExpandedFoldersChange(next)
        }
    }

    @ViewBuilder
    private func fileRow(for file: PackageFile) -> some View {
        if editingTarget == .file(file.path) {
            FileRenameField(
                name: $editingName,
                systemImage: icon(for: file),
                onCommit: {
                    onCommitRename(file)
                },
                onCancel: {
                    editingTarget = nil
                    editingName = ""
                }
            )
            .sidebarRowInsets(depth: depth)
            .sidebarRowBackground {
                fileRowBackground(for: file)
            }
        } else {
            HStack(spacing: 6) {
                fileIcon(for: file)

                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sidebarRowInsets(depth: depth)
                .sidebarRowBackground {
                    fileRowBackground(for: file)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let selection = FileTreeSelection.file(file.path)
                    let isCurrentSelection = selectedPath == file.path || (file.isPopoverPreviewable && renameClickTarget == selection)
                    if shouldBeginRename(for: selection, isCurrentSelection: isCurrentSelection) {
                        onBeginRename(file)
                    } else if file.isPopoverPreviewable {
                        previewedImageFile = file
                    } else {
                        onSelect(selection)
                    }
                }
                .contextMenu {
                    #if os(macOS)
                    if file.isPythonScript {
                        Button("Run in Terminal") {
                            onRunPythonScript(file.path)
                        }
                        Divider()
                    }
                    #endif

                    if canSetCompileTarget && file.isTypstSource {
                        Button("Set as Compile Target") {
                            onSetCompileTarget(file.path)
                        }
                    }
                    Button("Rename") {
                        onBeginRename(file)
                    }
                    Button("Duplicate") {
                        onDuplicateFile(file.path)
                    }
                    Button("Delete", role: .destructive) {
                        onDeleteFile(file.path)
                    }
                }
                // macOS: `.onDrag` propagates from child views (icon, text) up
                // to the drag source. SwiftUI's newer `.draggable` does not,
                // which makes only the empty Spacer area draggable.
                // iOS: `.draggable` is required so it coexists with
                // `.contextMenu` — the legacy `.onDrag` competes with the
                // context menu's long-press there and the drag never starts.
                #if os(macOS)
                .onDrag {
                    FileTreeDragPayload.itemProvider(for: file)
                } preview: {
                    dragPreview(for: file)
                }
                #else
                .draggable(PackageFileDragItem(file: file)) {
                    dragPreview(for: file)
                }
                #endif
                .popover(item: $previewedImageFile, arrowEdge: .trailing) { file in
                    PackageImagePreview(file: file, backgroundColor: .white)
                        .padding(16)
                        .frame(width: 720, height: 560)
                        .background(Color.white)
                        .presentationBackground(Color.white)
                }
        }
    }

    private func dragPreview(for file: PackageFile) -> some View {
        dragPreview(
            systemImage: icon(for: file),
            name: file.name,
            isCompileTarget: file.path == compileTargetPath
        )
    }

    private func dragPreview(systemImage: String, name: String, isCompileTarget: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(isCompileTarget ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(name)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .font(.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .fixedSize()
    }

    private func icon(for file: PackageFile) -> String {
        if file.path == compileTargetPath { return "smallcircle.filled.circle" }
        if file.isTypstSource { return "doc.plaintext" }
        if file.path.lowercased().hasSuffix(".png") || file.path.lowercased().hasSuffix(".jpg") {
            return "photo"
        }
        return "doc"
    }

    @ViewBuilder
    private func fileIcon(for file: PackageFile) -> some View {
        if file.path == compileTargetPath {
            Image(systemName: icon(for: file))
                .foregroundStyle(.tint)
                .frame(width: 18)
        } else {
            Image(systemName: icon(for: file))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private func shouldBeginRename(for selection: FileTreeSelection, isCurrentSelection: Bool) -> Bool {
        #if os(iOS)
        return false
        #else
        let now = Date()
        defer {
            renameClickTarget = selection
            renameClickDate = now
        }

        guard isCurrentSelection, renameClickTarget == selection else { return false }
        return now.timeIntervalSince(renameClickDate) >= 0.45
        #endif
    }

    private var isDropTargetedFolder: Bool {
        highlightedDropFolder == node.path
    }

    private var folderBackgroundOpacity: Double {
        if isDropTargetedFolder { return 0.16 }
        if selectedFolderPath == node.path { return 0.16 }
        return 0
    }

    @ViewBuilder
    private var folderRowBackground: some View {
        if folderBackgroundOpacity > 0 {
            Rectangle()
                .fill(.tint.opacity(folderBackgroundOpacity))
        }
    }

    @ViewBuilder
    private func fileRowBackground(for file: PackageFile) -> some View {
        if file.path == selectedPath {
            Rectangle()
                .fill(.tint.opacity(0.16))
        }
    }
}

private extension View {
    @ViewBuilder
    func platformSidebarColumnBackground() -> some View {
        // On macOS the NavigationSplitView sidebar column already paints the
        // native sidebar vibrancy; a custom NSVisualEffectView placed inside it
        // only blends against the opaque window backing and reads as flat gray.
        // Leaving the content transparent lets the real material show through.
        self
    }

    @ViewBuilder
    func platformSidebarToolbarBackground() -> some View {
        #if os(macOS)
        self
        #else
        self.background(.bar)
        #endif
    }

    @ViewBuilder
    func sidebarRowInsets(depth: Int = 0) -> some View {
        #if os(iOS)
        let leadingPadding = 16 + CGFloat(depth) * 22
        self
            .padding(.leading, leadingPadding)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        #else
        self
        #endif
    }

    @ViewBuilder
    func sidebarRowBackground<Background: View>(@ViewBuilder _ background: () -> Background) -> some View {
        #if os(iOS)
        self.iosSidebarRowBackground {
            background()
        }
        #else
        self.listRowBackground(background())
        #endif
    }

    @ViewBuilder
    func iosSidebarRowBackground<Background: View>(@ViewBuilder _ background: () -> Background) -> some View {
        #if os(iOS)
        self.background {
            background()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        #else
        self
        #endif
    }
}


struct FileRenameField: View {
    @Binding var name: String
    var systemImage: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didFinishEditing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            #if os(macOS)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    finish(onCommit)
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        finish(onCancel)
                    }
                }
            #else
            StemSelectingRenameTextField(
                text: $name,
                onCommit: { finish(onCommit) },
                onCancel: { finish(onCancel) }
            )
            #endif

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
            .onAppear {
                #if os(macOS)
                isFocused = true
                Task { @MainActor in
                    // Wait a tick so the field editor is installed before we
                    // narrow the selection to the stem.
                    try? await Task.sleep(for: .milliseconds(20))
                    selectStem()
                }
                #endif
            }
    }

    private func finish(_ action: @escaping () -> Void) {
        guard !didFinishEditing else { return }
        didFinishEditing = true
        DispatchQueue.main.async {
            action()
        }
    }

    #if os(macOS)
    /// Replaces the field editor's default "select all" with a selection that
    /// covers everything up to (but not including) the file extension, so
    /// typing replaces the basename and leaves the extension intact.
    private func selectStem() {
        guard let window = NSApp.keyWindow,
              let fieldEditor = window.firstResponder as? NSText else { return }
        let value = name as NSString
        let dotRange = value.range(of: ".", options: .backwards)
        // If there's no dot, or the only dot is at position 0 (a dotfile like
        // ".gitignore"), select the whole name — there's no extension to spare.
        let length: Int
        if dotRange.location == NSNotFound || dotRange.location == 0 {
            length = value.length
        } else {
            length = dotRange.location
        }
        fieldEditor.selectedRange = NSRange(location: 0, length: length)
    }
    #endif
}

#if os(iOS)
private struct StemSelectingRenameTextField: UIViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.borderStyle = .none
        textField.clearButtonMode = .never
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .done
        textField.font = .preferredFont(forTextStyle: .body)
        textField.delegate = context.coordinator
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel

        if textField.text != text {
            textField.text = text
        }

        guard !context.coordinator.didRequestFocus else { return }
        context.coordinator.didRequestFocus = true
        DispatchQueue.main.async {
            textField.becomeFirstResponder()
            context.coordinator.selectStem(in: textField)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onCancel: () -> Void
        var didRequestFocus = false
        private var didFinishEditing = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        @objc func textChanged(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            finish(with: textField.text ?? "", action: onCommit)
            textField.resignFirstResponder()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            finish(with: textField.text ?? "", action: onCancel)
        }

        func selectStem(in textField: UITextField) {
            let value = (textField.text ?? "") as NSString
            let dotRange = value.range(of: ".", options: .backwards)
            let stemLength: Int
            if dotRange.location == NSNotFound || dotRange.location == 0 {
                stemLength = value.length
            } else {
                stemLength = dotRange.location
            }

            guard let start = textField.position(from: textField.beginningOfDocument, offset: 0),
                  let end = textField.position(from: textField.beginningOfDocument, offset: stemLength),
                  let range = textField.textRange(from: start, to: end) else {
                return
            }
            textField.selectedTextRange = range
        }

        private func finish(with value: String, action: @escaping () -> Void) {
            guard !didFinishEditing else { return }
            didFinishEditing = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                text.wrappedValue = value
                action()
            }
        }
    }
}
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
    static let typesetPackageFileDrag = UTType(exportedAs: "com.twarge.typeset.package-file-drag", conformingTo: .json)
    static let typesetPackageFolderDrag = UTType(exportedAs: "com.twarge.typeset.package-folder-drag", conformingTo: .json)
}

private extension PackageFile {
    var exportedContentType: UTType {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) ?? .data
    }
}

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

private func isHiddenPackagePath(_ path: String) -> Bool {
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

#if os(macOS)
struct AppAppearanceConfigurator: NSViewRepresentable {
    var themePreference: ThemePreference

    func makeNSView(context: Context) -> NSView {
        AppearanceView(themePreference: themePreference)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let appearanceView = nsView as? AppearanceView else { return }
        appearanceView.themePreference = themePreference
    }

    final class AppearanceView: NSView {
        var themePreference: ThemePreference {
            didSet {
                guard oldValue != themePreference else { return }
                applyAppearance()
            }
        }

        init(themePreference: ThemePreference) {
            self.themePreference = themePreference
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            let appearance = themePreference.nsAppearance
            DispatchQueue.main.async {
                NSApp.appearance = appearance
                NSApp.windows.forEach { window in
                    window.appearance = appearance
                }
            }
        }
    }
}

struct DocumentProxyConfigurator: NSViewRepresentable {
    var fileURL: URL?
    var editedPath: String

    func makeNSView(context: Context) -> NSView {
        ProxyView(fileURL: fileURL, editedPath: editedPath)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let proxyView = nsView as? ProxyView else { return }
        proxyView.fileURL = fileURL
        proxyView.editedPath = editedPath
    }

    final class ProxyView: NSView {
        var fileURL: URL? {
            didSet {
                configureWindow()
            }
        }

        var editedPath: String {
            didSet {
                configureWindow()
            }
        }

        init(fileURL: URL?, editedPath: String) {
            self.fileURL = fileURL
            self.editedPath = editedPath
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        private func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            if UserDefaults.standard.object(forKey: "NSWindow Frame Typeset.MainWindow") == nil {
                window.setContentSize(NSSize(width: 1280, height: 860))
                window.center()
            }
            window.setFrameAutosaveName("Typeset.MainWindow")
            window.representedURL = fileURL
            window.title = windowTitle
        }

        private var windowTitle: String {
            guard let fileURL else { return "Typeset" }
            let documentTitle: String
            if fileURL.pathExtension.lowercased() == "typeset" {
                documentTitle = fileURL.deletingPathExtension().lastPathComponent
            } else {
                documentTitle = fileURL.lastPathComponent
            }
            guard !editedPath.isEmpty else { return documentTitle }
            return "\(documentTitle) - \(editedPath)"
        }
    }
}

struct SplitViewStateConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SplitStateView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let splitStateView = nsView as? SplitStateView else { return }
        splitStateView.configureSplitView()
    }

    final class SplitStateView: NSView {
        private var didSetInitialSidebarWidth = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSplitView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureSplitView()
        }

        func configureSplitView() {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let splitView = self.firstAncestor(ofType: NSSplitView.self) ?? self.window?.contentView?.firstDescendant(ofType: NSSplitView.self) else {
                    return
                }

                splitView.autosaveName = NSSplitView.AutosaveName("Typeset.WorkspaceSidebar")
                guard !self.didSetInitialSidebarWidth,
                      UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Typeset.WorkspaceSidebar") == nil,
                      splitView.arrangedSubviews.count > 1 else {
                    return
                }

                splitView.setPosition(320, ofDividerAt: 0)
                self.didSetInitialSidebarWidth = true
            }
        }
    }
}

private extension NSView {
    func firstAncestor<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        var current = superview
        while let view = current {
            if let match = view as? ViewType {
                return match
            }
            current = view.superview
        }
        return nil
    }

    func firstDescendant<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }
}

private extension ThemePreference {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
#endif

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


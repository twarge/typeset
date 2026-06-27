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
    @Binding var previewAutoRetriggerDelay: Double
    @Binding var windowChromePreference: WindowChromePreference
    @Binding var lspDebugLoggingEnabled: Bool
    // Shares the editor's persisted font-size key, so this control and any
    // open editor stay in sync.
    @AppStorage("sourceEditor.fontSize") private var editorFontSize = SourceEditorFont.defaultSize
    // Read at document creation in `TypesetDocument.init()`; this control just
    // writes the same global key (default registered in `TypesetApp.init`).
    @AppStorage("newDocument.includesSampleContent") private var newDocumentIncludesSampleContent = true
    #if os(macOS)
    // Snapshot of the sandbox folder grants, refreshed when the pane appears and
    // after each revoke so the list re-renders.
    @State private var grantedFolders: [String] = []
    #endif
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Editor")
                    .font(.subheadline.weight(.semibold))

                Toggle("Show Line Numbers", isOn: $showLineNumbers)
                Toggle("Check Spelling in Prose", isOn: $spellCheckingEnabled)
                Toggle("Ignore Typst Commands and Arguments", isOn: $spellCheckingIgnoresCommands)
                    .disabled(!spellCheckingEnabled)
                Toggle("Update References When Renaming or Moving Files", isOn: $updateReferencesOnRename)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("New Documents")
                    .font(.subheadline.weight(.semibold))

                Toggle("Include Sample Content", isOn: $newDocumentIncludesSampleContent)

                Text("Start new documents with a demonstration of Typst features instead of a blank file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(macOS)
            // Theme and split-orientation controls are macOS-only. iOS follows
            // the system appearance and always shows panes side by side.
            VStack(alignment: .leading, spacing: 14) {
                Text("Application")
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Theme")
                        .font(.subheadline)
                    Picker("Theme", selection: $themePreference) {
                        ForEach(ThemePreference.allCases) { preference in
                            Text(preference.title)
                                .tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Split Layout")
                        .font(.subheadline)
                    Picker("Split Layout", selection: $splitBehavior) {
                        ForEach(SplitBehavior.allCases) { behavior in
                            Label(behavior.title, systemImage: behavior.symbolName)
                                .tag(behavior)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Tall Window Threshold")
                            .font(.subheadline)
                        Spacer()
                        Text(tallSplitThreshold, format: .number.precision(.fractionLength(2)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Slider(value: $tallSplitThreshold, in: 0.8...1.8, step: 0.02)
                        .disabled(splitBehavior != .automatic)
                }
                .opacity(splitBehavior == .automatic ? 1 : 0.45)
            }
            #endif

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Distraction-Free Mode", isOn: distractionFreeModeBinding)

                Text("Hide the toolbar and title bar until you move the pointer to the top of the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

                Text("How long to wait after you stop typing before recompiling the preview. Higher values recompile less often while you edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recompile Delay")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(previewAutoRetriggerDelay, specifier: "%.2f")s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $previewAutoRetriggerDelay, in: 0...1, step: 0.05)

                Text("When Auto Preview is on, how long to wait after each compile before automatically recompiling again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if os(macOS)
            VStack(alignment: .leading, spacing: 10) {
                Text("Export")
                    .font(.subheadline.weight(.semibold))

                Toggle("Export PDF on Close", isOn: $autoExportPDFOnClose)
            }
            #endif

            #if os(macOS)
            folderAccessSection
            #endif

            VStack(alignment: .leading, spacing: 6) {
                Text("Typeset is made by Twarge LLC.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Link("hello@twarge.com", destination: URL(string: "mailto:hello@twarge.com")!)
                    .font(.footnote)
            }
        }
    }

    private var distractionFreeModeBinding: Binding<Bool> {
        Binding(
            get: { windowChromePreference.usesDistractionFreeChrome },
            set: { windowChromePreference = $0 ? .none : .heavy }
        )
    }

    #if os(macOS)
    @ViewBuilder
    private var folderAccessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder Access")
                .font(.subheadline.weight(.semibold))

            Text("Folders you've granted Typeset access to outside its sandbox.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if grantedFolders.isEmpty {
                Text("No folders granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(grantedFolders, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Spacer(minLength: 8)
                            Button {
                                withAnimation {
                                    FolderAccessStore.revokeAccess(toPath: path)
                                    grantedFolders = FolderAccessStore.grantedPaths()
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Revoke access to \(path)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    }
                }
            }
        }
        .onAppear { grantedFolders = FolderAccessStore.grantedPaths() }
    }
    #endif
}

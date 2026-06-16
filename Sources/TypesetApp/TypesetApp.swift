// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TypesetCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

@main
struct TypesetApp: App {
    init() {
        TypesetBundledFonts.register()
        UserDefaults.standard.register(defaults: [
            "sourceEditor.showLineNumbers": false,
            "sourceEditor.spellCheckingIgnoresCommands": true,
            "export.autoPDFOnClose": false,
            "preview.renderWarmupDelay": 0.5,
            "developer.lspDebugLogging": false
        ])
    }

    var body: some Scene {
        DocumentGroup(newDocument: TypesetDocument()) { file in
            TypesetWorkspaceView(document: file.$document, fileURL: file.fileURL)
        }
        .commands {
            SidebarCommands()
            TypesetCommands()
            #if os(macOS)
            TypesetAboutCommands()
            #endif
        }

        #if os(iOS)
        DocumentGroupLaunchScene("Typeset") {
            // Use the plain `NewDocumentButton` (Apple's documented launch-scene
            // pattern). It delegates to the `DocumentGroup`'s `newDocument:`
            // closure above, which both creates the document AND transitions to
            // the editor. The `for:contentType:prepareDocument:` variant we used
            // before saved the new package to Files but never presented the
            // editor (the editor's `onAppear` never fired) — its `prepareDocument`
            // closure was also redundant, since it only returned `TypesetDocument()`,
            // which is exactly what `newDocument:` constructs.
            NewDocumentButton("Create Document")
        } background: {
            Color.clear
        }
        #endif
    }
}

struct TypesetCommandSet: Equatable {
    var showSource: () -> Void
    var showSourceAndPreview: () -> Void
    var showPreview: () -> Void
    var exportPDF: () -> Void
    var exportPDFToDefaultLocation: () -> Void
    var canExportPDFToDefaultLocation: Bool
    var newFolder: () -> Void
    var toggleLogs: () -> Void
    var requestCompletion: () -> Void
    var showFindReplace: () -> Void
    var showFindInFiles: () -> Void
    var findNext: () -> Void
    var findPrevious: () -> Void
    var replaceCurrentMatch: () -> Void
    var toggleParagraphComment: () -> Void
    var insertFigure: () -> Void
    var insertTable: () -> Void
    var showLineNumbers: Bool
    var setShowLineNumbers: (Bool) -> Void
    var showSettings: () -> Void

    // The workspace rebuilds a fresh `TypesetCommandSet` on every body
    // evaluation and publishes it via `.focusedSceneValue`. Closures aren't
    // comparable, so without an `Equatable` conformance SwiftUI treats every
    // republish as a change, re-invalidates the publishing view, and spins an
    // infinite render loop (blank editor on iOS). The closures only ever act
    // on live `@State` storage, so two command sets are equivalent for focus
    // purposes when their value-typed inputs match — compare only those.
    static func == (lhs: TypesetCommandSet, rhs: TypesetCommandSet) -> Bool {
        lhs.canExportPDFToDefaultLocation == rhs.canExportPDFToDefaultLocation &&
        lhs.showLineNumbers == rhs.showLineNumbers
    }
}

struct TypesetCommandSetKey: FocusedValueKey {
    typealias Value = TypesetCommandSet
}

extension FocusedValues {
    var typesetCommands: TypesetCommandSet? {
        get { self[TypesetCommandSetKey.self] }
        set { self[TypesetCommandSetKey.self] = newValue }
    }
}

struct TypesetCommands: Commands {
    @FocusedValue(\.typesetCommands) private var commands

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") {
                commands?.newFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(commands == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Export PDF...") {
                commands?.exportPDF()
            }
            .disabled(commands == nil)

            Button("Export PDF to Default Location") {
                commands?.exportPDFToDefaultLocation()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(commands == nil || commands?.canExportPDFToDefaultLocation != true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Find and Replace...") {
                commands?.showFindReplace()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(commands == nil)

            Button("Find in Files...") {
                commands?.showFindInFiles()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(commands == nil)

            Button("Find Next") {
                commands?.findNext()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(commands == nil)

            Button("Find Previous") {
                commands?.findPrevious()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(commands == nil)

            Button("Replace") {
                commands?.replaceCurrentMatch()
            }
            .disabled(commands == nil)

            Button("Toggle Comment") {
                commands?.toggleParagraphComment()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(commands == nil)
        }

        CommandMenu("Insert") {
            Button("Insert Figure") {
                commands?.insertFigure()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(commands == nil)

            Button("Insert Table") {
                commands?.insertTable()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(commands == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Source") {
                commands?.showSource()
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(commands == nil)

            Button("Show Source and Preview") {
                commands?.showSourceAndPreview()
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(commands == nil)

            Button("Show Preview") {
                commands?.showPreview()
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(commands == nil)

            Divider()

            Button("Show Logs") {
                commands?.toggleLogs()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(commands == nil)

            Toggle("Show Line Numbers", isOn: Binding(
                get: { commands?.showLineNumbers ?? false },
                set: { commands?.setShowLineNumbers($0) }
            ))
            .disabled(commands == nil)

            Button("Complete") {
                commands?.requestCompletion()
            }
            .keyboardShortcut(" ", modifiers: .command)
            .disabled(commands == nil)

            Button("Settings...") {
                commands?.showSettings()
            }
            #if os(macOS)
            .keyboardShortcut(",", modifiers: .command)
            #endif
            .disabled(commands == nil)
        }
    }
}

#if os(macOS)
struct TypesetAboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Typeset") {
                TypesetAboutPanel.show()
            }
        }
    }
}

@MainActor
private enum TypesetAboutPanel {
    private static let makerText = "Typeset is made by Twarge LLC."
    private static let supportEmail = "hello@twarge.com"

    static func show() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Typeset",
            .applicationVersion: value(for: "CFBundleShortVersionString") ?? "1.0",
            .version: value(for: "CFBundleVersion") ?? "1",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var credits: NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 6

        let text = "\(makerText)\n\(supportEmail)\n\nTypst \(TypstRuntime.typstVersion)\n\n\(acknowledgementText)"
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        if let emailRange = text.range(of: supportEmail),
           let mailURL = URL(string: "mailto:\(supportEmail)") {
            let nsRange = NSRange(emailRange, in: text)
            attributed.addAttributes([
                .link: mailURL,
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: nsRange)
        }

        return attributed
    }

    private static var acknowledgementText: String {
        [
            text(named: "Acknowledgements"),
            section("Typst License", file: "Typst-LICENSE"),
            section("Typst Third-Party Notices", file: "Typst-NOTICE"),
            section("Tinymist License", file: "Tinymist-LICENSE"),
            section("Tinymist cmark-writer License", file: "Tinymist-cmark-writer-LICENSE"),
            section("Fira Code License", file: "FiraCode-LICENSE")
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func section(_ title: String, file: String) -> String {
        let body = text(named: file)
        guard !body.isEmpty else { return "" }
        return "\(title)\n\n\(body)"
    }

    private static func text(named name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func value(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
#endif

struct TypesetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.typesetPackage, .typstSource] }
    static var writableContentTypes: [UTType] { [.typesetPackage, .typstSource] }

    var package: DocumentPackage
    var openedContentType: UTType

    init() {
        package = try! DocumentPackage()
        openedContentType = .typesetPackage
    }

    init(configuration: ReadConfiguration) throws {
        openedContentType = configuration.contentType
        if configuration.contentType.conforms(to: .typstSource) {
            let data = configuration.file.regularFileContents ?? Data()
            package = try DocumentPackage(
                files: [PackageFile(path: configuration.file.preferredFilename ?? "main.typ", data: data)],
                compileTargetPath: configuration.file.preferredFilename ?? "main.typ"
            )
        } else {
            package = try DocumentPackage(fileWrapper: configuration.file)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType.conforms(to: .typstSource),
           let compileTargetPath = package.mainTypstPath,
           let file = package.files.first(where: { $0.path == compileTargetPath }) {
            let wrapper = FileWrapper(regularFileWithContents: file.data)
            wrapper.preferredFilename = file.name
            return wrapper
        }

        let wrapper = package.fileWrapper()
        wrapper.preferredFilename = configuration.existingFile?.preferredFilename ?? "Untitled.typeset"
        return wrapper
    }
}

struct PDFExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    static var writableContentTypes: [UTType] { [.pdf] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

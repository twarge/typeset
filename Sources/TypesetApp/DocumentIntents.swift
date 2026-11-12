// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import AppIntents
import Foundation
import TypesetCore
import UniformTypeIdentifiers

/// A file in, a PDF out: the same compile as `CompileTypstIntent`, for
/// shortcuts that start from a document in Files or Finder rather than from
/// text. A Typeset package brings its images and other sources with it; a
/// lone `.typ` file is compiled on its own, so anything it imports by
/// relative path is out of reach.
struct ExportTypstFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Typst File as PDF"
    static let description = IntentDescription(
        "Compiles a Typst source file or a Typeset package into a PDF. A single source file is compiled by itself, without the files beside it.")

    // The metadata extractor accepts only the system's own types here, so
    // Typst source and Typeset packages are named by what they conform to.
    @Parameter(title: "File", supportedContentTypes: [.package, .text])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$file) as a PDF")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let package = try Self.package(from: file)
        let data = try await TypstRenderer().previewPDF(package: package).data
        let name = (file.filename as NSString).deletingPathExtension
        return .result(value: IntentFile(data: data, filename: (name.isEmpty ? "Document" : name) + ".pdf", type: .pdf))
    }

    private static func package(from file: IntentFile) throws -> DocumentPackage {
        if let url = file.fileURL {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return try DocumentPackage(fileWrapper: FileWrapper(url: url, options: [.immediate]))
            }
        }
        return try DocumentPackage(files: [PackageFile(path: "main.typ", data: file.data)])
    }
}

/// Makes a Typst source file from text, for shortcuts that assemble a
/// document and want to keep it, not only its PDF.
struct CreateTypstFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Typst File"
    static let description = IntentDescription(
        "Creates a Typst source file from text, ready to save or to open in Typeset.")

    @Parameter(title: "Source", inputOptions: String.IntentInputOptions(multiline: true))
    var source: String

    @Parameter(title: "Name", default: "Document")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Create a Typst file named \(\.$name) from \(\.$source)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        .result(value: IntentFile(data: Data(source.utf8), filename: name + ".typ", type: .typstSource))
    }
}

/// Lets a Focus turn on distraction-free mode while it is active, from the
/// Focus settings on any of the user's devices.
struct TypesetFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Typeset Appearance"
    static let description: IntentDescription? = IntentDescription(
        "Hides Typeset's window chrome while this Focus is on.")

    @Parameter(title: "Distraction-Free Mode", default: false)
    var distractionFree: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "Typeset",
            subtitle: distractionFree ? "Distraction-free mode" : "No change"
        )
    }

    /// The system calls this when the Focus turns on, and again with the
    /// parameter back at its default when it turns off.
    func perform() async throws -> some IntentResult {
        await FocusFilterState.apply(distractionFree: distractionFree)
        return .result()
    }
}

/// Applies a Focus filter by writing the same preference the Settings toggle
/// writes, remembering what it replaced so the end of the Focus puts it back.
enum FocusFilterState {
    static let windowChromeKey = "workspace.windowChrome"
    private static let savedKey = "focusFilter.savedWindowChrome"

    static func apply(distractionFree: Bool, defaults: UserDefaults = .standard) {
        if distractionFree {
            if defaults.string(forKey: savedKey) == nil {
                defaults.set(
                    defaults.string(forKey: windowChromeKey) ?? WindowChromePreference.heavy.rawValue,
                    forKey: savedKey
                )
            }
            defaults.set(WindowChromePreference.none.rawValue, forKey: windowChromeKey)
        } else if let saved = defaults.string(forKey: savedKey) {
            defaults.set(saved, forKey: windowChromeKey)
            defaults.removeObject(forKey: savedKey)
        }
    }
}

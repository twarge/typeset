// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import AppIntents
import Foundation
import TypesetCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// One-file compilation for the intent and the macOS service: wraps bare
/// Typst source as a single-file package and runs the same embedded
/// compiler the editor uses — packages, fonts, cache and all.
enum TypstCompiler {
    static func pdf(from source: String) async throws -> Data {
        let package = try DocumentPackage(
            files: [PackageFile(path: "main.typ", data: Data(source.utf8))])
        return try await TypstRenderer().previewPDF(package: package).data
    }
}

/// The compiler as a verb for Shortcuts, Spotlight, and other apps: Typst
/// source in, a PDF file out. On iOS this is how another app reaches a
/// Typst compiler at all — a shortcut chains the result into Quick Look,
/// Save File, or a share sheet.
struct CompileTypstIntent: AppIntent {
    static let title: LocalizedStringResource = "Compile Typst"
    static let description = IntentDescription(
        "Compiles Typst source text into a PDF with Typeset's embedded Typst compiler.")

    @Parameter(title: "Source", inputOptions: String.IntentInputOptions(multiline: true))
    var source: String

    @Parameter(title: "Name", default: "Document")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Compile \(\.$source) into a PDF named \(\.$name)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data = try await TypstCompiler.pdf(from: source)
        return .result(value: IntentFile(data: data, filename: name + ".pdf", type: .pdf))
    }
}

struct TypesetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompileTypstIntent(),
            phrases: ["Compile Typst with \(.applicationName)"],
            shortTitle: "Compile Typst",
            systemImageName: "doc.richtext")
    }
}

#if os(macOS)
/// Answers `Compile Typst to PDF` from the Services menu — and from other
/// apps calling `NSPerformService` with Typst text on a pasteboard, which is
/// how Calcium hands a document over for typesetting without leaving its
/// own sandbox.
final class CompileService: NSObject {
    @objc func compileTypst(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let source = pasteboard.string(forType: .string) else {
            error.pointee = "No Typst source on the pasteboard." as NSString
            return
        }
        // Service handlers are synchronous and arrive on the main thread,
        // and the compile pipeline is MainActor-isolated (the project
        // default), so blocking here on a semaphore would deadlock: the
        // task could never reach the actor this thread is sitting on.
        // Spin the run loop instead — that keeps the main queue draining,
        // the actor's awaits progressing, and the Rust work queue does the
        // actual compiling off-thread.
        var outcome: Result<Data, Error>?
        Task { @MainActor in
            do {
                outcome = .success(try await TypstCompiler.pdf(from: source))
            } catch let failure {
                outcome = .failure(failure)
            }
        }
        let deadline = Date(timeIntervalSinceNow: 120)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        switch outcome {
        case .success(let data):
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .pdf)
        case .failure(let failure):
            error.pointee = failure.localizedDescription as NSString
        case nil:
            error.pointee = "Typst compilation timed out." as NSString
        }
    }
}

/// Registers the service provider once the app is up.
@MainActor
final class TypesetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = CompileService()
    }
}
#endif

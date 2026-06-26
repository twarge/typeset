// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(TypesetTinymist)
import TypesetTinymist
#endif

public enum TypstRenderError: Error, LocalizedError, Sendable {
    case noMainFile
    case packageStorageUnavailable
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noMainFile:
            "No Typst source file was found in this package."
        case .packageStorageUnavailable:
            "Typeset could not create a package cache for automatic Typst imports."
        case .commandFailed(let message):
            message
        }
    }
}

public protocol TypstRendering: Sendable {
    func preview(package: DocumentPackage) async throws -> HTMLPreview
    func previewPDF(package: DocumentPackage) async throws -> PDFPreview
    func exportPDF(package: DocumentPackage, to outputURL: URL) async throws
}

public struct PDFPreview: Equatable, Sendable {
    public var data: Data
    public var sourceRects: [PreviewSourceRect]
    /// Compiler diagnostics from this render, formatted as
    /// `file:line:column: severity: message` lines (empty when there were none).
    /// Carried so warnings surface even when the compile succeeds.
    public var diagnosticsMessage: String

    public init(data: Data, sourceRects: [PreviewSourceRect] = [], diagnosticsMessage: String = "") {
        self.data = data
        self.sourceRects = sourceRects
        self.diagnosticsMessage = diagnosticsMessage
    }
}

public struct TypstRenderer: TypstRendering {
    private let previewBuilder: PreviewHTMLBuilder

    public init(previewBuilder: PreviewHTMLBuilder = PreviewHTMLBuilder()) {
        self.previewBuilder = previewBuilder
    }

    public func preview(package: DocumentPackage) async throws -> HTMLPreview {
        guard let mainPath = package.mainTypstPath else { throw TypstRenderError.noMainFile }

        #if canImport(TypesetTinymist)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        let response = try await callEmbeddedTypst {
            typeset_typst_compile_svg(
                workspace.path,
                mainPath,
                packageStorage.localPackagesURL.path,
                packageStorage.packageCacheURL.path
            )
        }
        guard response.ok else {
            throw TypstRenderError.commandFailed(response.failureMessage(fallback: "Typst preview failed."))
        }
        guard !response.pages.isEmpty else {
            throw TypstRenderError.commandFailed("Typst preview did not produce any SVG pages.")
        }
        let sourceRects = response.sourceRects.compactMap { sourceRect in
            previewSourceRect(from: sourceRect, package: package)
        }
        return previewBuilder.build(
            svgPages: response.pages,
            sourcePath: mainPath,
            sourceText: package.text(for: mainPath),
            sourceRects: sourceRects
        )
        #elseif os(macOS)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputTemplate = workspace.appending(path: "preview-page-{0p}.svg")
        let inputURL = workspace.appending(path: mainPath)
        let command = TypstToolLocator().typstCommand()
        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        try runTypst(
            command: command,
            arguments: [
                "compile",
                "--root", workspace.path,
            ] + packageStorage.compileArguments + [
                inputURL.path,
                outputTemplate.path,
            ],
            fallbackErrorMessage: "Typst preview failed."
        )

        let pages = try SVGPreviewPageLoader().loadPages(from: workspace)
        return previewBuilder.build(
            svgPages: pages,
            sourcePath: mainPath,
            sourceText: package.text(for: mainPath)
        )
        #else
        previewBuilder.build(package: package)
        #endif
    }

    public func quickLookPreview(package: DocumentPackage) async throws -> HTMLPreview {
        guard let mainPath = package.mainTypstPath else { throw TypstRenderError.noMainFile }

        #if canImport(TypesetTinymist)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        let response = try await callEmbeddedTypst {
            typeset_typst_compile_html(
                workspace.path,
                mainPath,
                packageStorage.localPackagesURL.path,
                packageStorage.packageCacheURL.path
            )
        }
        guard response.ok else {
            throw TypstRenderError.commandFailed(response.failureMessage(fallback: "Typst HTML preview failed."))
        }
        guard let html = response.html, !html.isEmpty else {
            throw TypstRenderError.commandFailed("Typst HTML preview did not produce HTML.")
        }
        return previewBuilder.buildQuickLook(compiledHTML: html)
        #elseif os(macOS)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputURL = workspace.appending(path: "quicklook.html")
        let inputURL = workspace.appending(path: mainPath)
        let command = TypstToolLocator().typstCommand()
        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        try runTypst(
            command: command,
            arguments: [
                "compile",
                "--features", "html",
                "--root", workspace.path,
            ] + packageStorage.compileArguments + [
                inputURL.path,
                outputURL.path,
            ],
            fallbackErrorMessage: "Typst HTML preview failed."
        )
        return previewBuilder.buildQuickLook(compiledHTML: try String(contentsOf: outputURL, encoding: .utf8))
        #else
        return previewBuilder.build(package: package)
        #endif
    }

    public func previewPDF(package: DocumentPackage) async throws -> PDFPreview {
        guard let mainPath = package.mainTypstPath else { throw TypstRenderError.noMainFile }

        #if canImport(TypesetTinymist)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        let response = try await callEmbeddedTypst {
            typeset_typst_compile_pdf(
                workspace.path,
                mainPath,
                packageStorage.localPackagesURL.path,
                packageStorage.packageCacheURL.path
            )
        }
        guard response.ok else {
            throw TypstRenderError.commandFailed(response.failureMessage(fallback: "Typst preview failed."))
        }
        guard let encodedPDF = response.pdfBase64,
              let data = Data(base64Encoded: encodedPDF) else {
            throw TypstRenderError.commandFailed("Typst preview did not produce PDF data.")
        }
        let sourceRects = response.sourceRects.compactMap { sourceRect in
            previewSourceRect(from: sourceRect, package: package)
        }
        return PDFPreview(data: data, sourceRects: sourceRects, diagnosticsMessage: response.diagnosticsMessage)
        #elseif os(macOS)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let outputURL = workspace.appending(path: "preview.pdf")
        let inputURL = workspace.appending(path: mainPath)
        let command = TypstToolLocator().typstCommand()
        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        try runTypst(
            command: command,
            arguments: [
                "compile",
                "--root", workspace.path,
            ] + packageStorage.compileArguments + [
                inputURL.path,
                outputURL.path,
            ],
            fallbackErrorMessage: "Typst preview failed."
        )
        return PDFPreview(data: try Data(contentsOf: outputURL))
        #else
        throw TypstRenderError.commandFailed("PDF preview requires embedded Typst.")
        #endif
    }

    public func exportPDF(package: DocumentPackage, to outputURL: URL) async throws {
        guard let mainPath = package.mainTypstPath else { throw TypstRenderError.noMainFile }

        #if canImport(TypesetTinymist)
        let workspace = try TemporaryPackageWriter().write(package: package)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        let response = try await callEmbeddedTypst {
            typeset_typst_compile_pdf(
                workspace.path,
                mainPath,
                packageStorage.localPackagesURL.path,
                packageStorage.packageCacheURL.path
            )
        }
        guard response.ok else {
            throw TypstRenderError.commandFailed(response.failureMessage(fallback: "Typst export failed."))
        }
        guard let encodedPDF = response.pdfBase64,
              let data = Data(base64Encoded: encodedPDF) else {
            throw TypstRenderError.commandFailed("Typst export did not produce PDF data.")
        }
        try data.write(to: outputURL)
        #elseif os(macOS)
        let workspace = try TemporaryPackageWriter().write(package: package)
        let inputURL = workspace.appending(path: mainPath)
        let command = TypstToolLocator().typstCommand()
        let packageStorage = try TypstPackageStorage.appSupportStorage()
        try packageStorage.createDirectories()

        try runTypst(
            command: command,
            arguments: [
                "compile",
                "--root", workspace.path,
            ] + packageStorage.compileArguments + [
                inputURL.path,
                outputURL.path,
            ],
            fallbackErrorMessage: "Typst export failed."
        )
        #else
        throw TypstRenderError.commandFailed("PDF export currently requires the bundled Typst command-line tool on macOS.")
        #endif
    }

    #if canImport(TypesetTinymist)
    private func callEmbeddedTypst(
        _ body: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?
    ) async throws -> EmbeddedTypstRenderResponse {
        try await EmbeddedRustWorkQueue.rendering.run {
            guard let pointer = body() else {
                throw TypstRenderError.commandFailed("Embedded Typst returned no response.")
            }
            defer { typeset_tinymist_string_free(pointer) }
            let json = String(cString: pointer)
            guard let data = json.data(using: .utf8),
                  let response = try? JSONDecoder().decode(EmbeddedTypstRenderResponse.self, from: data) else {
                throw TypstRenderError.commandFailed(json.isEmpty ? "Embedded Typst returned an invalid response." : json)
            }
            return response
        }
    }

    private func previewSourceRect(from rect: EmbeddedTypstSourceRect, package: DocumentPackage) -> PreviewSourceRect? {
        guard package.files.contains(where: { $0.path == rect.file }) else { return nil }
        let text = package.text(for: rect.file)
        let start = Self.utf16Offset(forUTF8Offset: rect.startUTF8, in: text)
        let end = Self.utf16Offset(forUTF8Offset: rect.endUTF8, in: text)
        return PreviewSourceRect(
            page: rect.page,
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
            range: SourceRange(path: rect.file, start: start, end: max(start, end))
        )
    }

    private static func utf16Offset(forUTF8Offset offset: Int, in text: String) -> Int {
        let utf8 = text.utf8
        let clamped = min(max(0, offset), utf8.count)
        var utf8Index = utf8.index(utf8.startIndex, offsetBy: clamped)
        while utf8Index > utf8.startIndex && String.Index(utf8Index, within: text) == nil {
            utf8Index = utf8.index(before: utf8Index)
        }
        guard let stringIndex = String.Index(utf8Index, within: text),
              let utf16Index = stringIndex.samePosition(in: text.utf16) else {
            return text.utf16.count
        }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }
    #endif

    #if os(macOS)
    private func runTypst(command: TypstCommand, arguments: [String], fallbackErrorMessage: String) throws {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.argumentsPrefix + arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TypstRenderError.commandFailed(message.isEmpty ? fallbackErrorMessage : message)
        }
    }
    #endif
}

#if canImport(TypesetTinymist)
private struct EmbeddedTypstRenderResponse: Decodable, Sendable {
    var ok: Bool
    var message: String?
    var pages: [String]
    var pdfBase64: String?
    var html: String?
    var diagnostics: [EmbeddedTypstDiagnostic]
    var sourceRects: [EmbeddedTypstSourceRect]

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case pages
        case pdfBase64 = "pdf_base64"
        case html
        case diagnostics
        case sourceRects = "source_rects"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        pages = try container.decodeIfPresent([String].self, forKey: .pages) ?? []
        pdfBase64 = try container.decodeIfPresent(String.self, forKey: .pdfBase64)
        html = try container.decodeIfPresent(String.self, forKey: .html)
        diagnostics = try container.decodeIfPresent([EmbeddedTypstDiagnostic].self, forKey: .diagnostics) ?? []
        sourceRects = try container.decodeIfPresent([EmbeddedTypstSourceRect].self, forKey: .sourceRects) ?? []
    }

    /// All diagnostics formatted as `file:line:column: severity: message` lines,
    /// regardless of `ok` — so warnings can be surfaced on a successful compile.
    var diagnosticsMessage: String {
        diagnostics
            .map { "\($0.file):\($0.line):\($0.column): \($0.severity): \($0.message)" }
            .joined(separator: "\n")
    }

    func failureMessage(fallback: String) -> String {
        if let message, !message.isEmpty {
            return message
        }
        return diagnosticsMessage.isEmpty ? fallback : diagnosticsMessage
    }
}

private struct EmbeddedTypstDiagnostic: Decodable, Sendable {
    var file: String
    var line: Int
    var column: Int
    var severity: String
    var message: String
}

private struct EmbeddedTypstSourceRect: Decodable, Sendable {
    var page: Int
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var file: String
    var startUTF8: Int
    var endUTF8: Int

    enum CodingKeys: String, CodingKey {
        case page
        case x
        case y
        case width
        case height
        case file
        case startUTF8 = "start_utf8"
        case endUTF8 = "end_utf8"
    }
}
#endif

public struct SVGPreviewPageLoader: Sendable {
    public init() {}

    public func loadPages(from directory: URL, fileManager: FileManager = .default) throws -> [String] {
        let pageURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "svg" && $0.lastPathComponent.hasPrefix("preview-page-") }
        .sorted { lhs, rhs in
            pageNumber(in: lhs) < pageNumber(in: rhs)
        }

        let pages = try pageURLs.map { url in
            try String(contentsOf: url, encoding: .utf8)
        }

        guard !pages.isEmpty else {
            throw TypstRenderError.commandFailed("Typst preview did not produce any SVG pages.")
        }

        return pages
    }

    private func pageNumber(in url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        guard let value = name.split(separator: "-").last, let page = Int(value) else {
            return Int.max
        }
        return page
    }
}

public struct TypstPackageStorage: Equatable, Sendable {
    public var localPackagesURL: URL
    public var packageCacheURL: URL

    public init(localPackagesURL: URL, packageCacheURL: URL) {
        self.localPackagesURL = localPackagesURL
        self.packageCacheURL = packageCacheURL
    }

    public static func appSupportStorage(fileManager: FileManager = .default) throws -> TypstPackageStorage {
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw TypstRenderError.packageStorageUnavailable
        }

        let root = applicationSupportURL
            .appending(path: "Typeset", directoryHint: .isDirectory)
            .appending(path: "Typst", directoryHint: .isDirectory)
            .appending(path: "Packages", directoryHint: .isDirectory)

        return TypstPackageStorage(
            localPackagesURL: root.appending(path: "local", directoryHint: .isDirectory),
            packageCacheURL: root.appending(path: "cache", directoryHint: .isDirectory)
        )
    }

    public var compileArguments: [String] {
        [
            "--package-path", localPackagesURL.path,
            "--package-cache-path", packageCacheURL.path,
        ]
    }

    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: localPackagesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packageCacheURL, withIntermediateDirectories: true)
    }
}

public struct TypstCommand: Sendable {
    public var executableURL: URL
    public var argumentsPrefix: [String]
}

public struct TypstToolLocator: Sendable {
    public init() {}

    public func typstCommand() -> TypstCommand {
        if let bundled = Bundle.main.url(forResource: "typst", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return TypstCommand(executableURL: bundled, argumentsPrefix: [])
        }

        if let override = ProcessInfo.processInfo.environment["TYPESET_TYPST_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return TypstCommand(executableURL: URL(fileURLWithPath: override), argumentsPrefix: [])
        }

        let localBuild = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "Vendor/typst/target/release/typst")
        if FileManager.default.isExecutableFile(atPath: localBuild.path) {
            return TypstCommand(executableURL: localBuild, argumentsPrefix: [])
        }
        return TypstCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false"), argumentsPrefix: [])
    }
}

public struct TemporaryPackageWriter: Sendable {
    public init() {}

    public func write(package: DocumentPackage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Typeset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for folder in package.allFolderPaths {
            let url = directory.appending(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        for file in package.files {
            let url = directory.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: url)
        }

        return directory
    }
}

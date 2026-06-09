// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

private enum TypstLanguageDebug {
    private static let defaultsKey = "developer.lspDebugLogging"

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        print("[Typeset LSP] \(message())")
        #endif
    }

    static func labels(_ items: [TypstCompletionItem], limit: Int = 6) -> String {
        items.prefix(limit).map(\.label).joined(separator: ", ")
    }
}

public enum TypstDiagnosticSeverity: String, Codable, Sendable {
    case error
    case warning
    case information
}

public struct TypstSourceDiagnostic: Equatable, Codable, Sendable, Identifiable {
    public var id: String { "\(file):\(range.location):\(range.length):\(message)" }
    public var file: String
    public var range: NSRange
    public var severity: TypstDiagnosticSeverity
    public var message: String

    public init(file: String, range: NSRange, severity: TypstDiagnosticSeverity, message: String) {
        self.file = file
        self.range = range
        self.severity = severity
        self.message = message
    }
}

public struct TypstCompletionItem: Equatable, Codable, Sendable, Identifiable {
    public var id: String { "\(label):\(insertText)" }
    public var label: String
    public var detail: String
    public var insertText: String
    public var insertTextFormat: TypstCompletionInsertTextFormat
    public var replacementRange: NSRange?
    public var filterText: String
    public var sortText: String
    public var documentation: String
    public var kind: String

    public init(
        label: String,
        detail: String = "",
        insertText: String? = nil,
        insertTextFormat: TypstCompletionInsertTextFormat = .plainText,
        replacementRange: NSRange? = nil,
        filterText: String? = nil,
        sortText: String? = nil,
        documentation: String = "",
        kind: String = "text"
    ) {
        self.label = label
        self.detail = detail
        self.insertText = insertText ?? label
        self.insertTextFormat = insertTextFormat
        self.replacementRange = replacementRange
        self.filterText = filterText ?? label
        self.sortText = sortText ?? label
        self.documentation = documentation
        self.kind = kind
    }
}

public enum TypstCompletionInsertTextFormat: String, Codable, Sendable {
    case plainText = "plain_text"
    case snippet
}

public struct TypstResolvedCompletionInsertion: Equatable, Sendable {
    public var text: String
    public var selectionRange: NSRange

    public init(text: String, selectionRange: NSRange) {
        self.text = text
        self.selectionRange = selectionRange
    }
}

public enum TypstCompletionSnippet {
    public static func resolve(_ insertText: String, format: TypstCompletionInsertTextFormat) -> TypstResolvedCompletionInsertion {
        guard format == .snippet else {
            let length = (insertText as NSString).length
            return TypstResolvedCompletionInsertion(
                text: insertText,
                selectionRange: NSRange(location: length, length: 0)
            )
        }

        var output = ""
        var firstTabStopRange: NSRange?
        var finalTabStopLocation: Int?
        var index = insertText.startIndex

        func outputLength() -> Int {
            (output as NSString).length
        }

        while index < insertText.endIndex {
            let character = insertText[index]

            if character == "\\" {
                let next = insertText.index(after: index)
                if next < insertText.endIndex {
                    output.append(insertText[next])
                    index = insertText.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            guard character == "$" else {
                output.append(character)
                index = insertText.index(after: index)
                continue
            }

            let next = insertText.index(after: index)
            guard next < insertText.endIndex else {
                output.append(character)
                index = next
                continue
            }

            if insertText[next] == "{" {
                guard let close = insertText[next...].firstIndex(of: "}") else {
                    output.append(character)
                    index = next
                    continue
                }

                let bodyStart = insertText.index(after: next)
                let body = String(insertText[bodyStart..<close])
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let number = parts.first.flatMap { Int($0) }
                let placeholder = parts.count > 1 ? String(parts[1]) : ""
                let start = outputLength()
                output.append(placeholder)
                let range = NSRange(location: start, length: (placeholder as NSString).length)
                if number == 0 {
                    finalTabStopLocation = start
                } else if number != nil, firstTabStopRange == nil {
                    firstTabStopRange = range
                }
                index = insertText.index(after: close)
                continue
            }

            if insertText[next].isNumber {
                var end = next
                while end < insertText.endIndex, insertText[end].isNumber {
                    end = insertText.index(after: end)
                }
                let number = Int(insertText[next..<end])
                let location = outputLength()
                if number == 0 {
                    finalTabStopLocation = location
                } else if number != nil, firstTabStopRange == nil {
                    firstTabStopRange = NSRange(location: location, length: 0)
                }
                index = end
                continue
            }

            output.append(character)
            index = next
        }

        let selection = firstTabStopRange
            ?? finalTabStopLocation.map { NSRange(location: $0, length: 0) }
            ?? NSRange(location: outputLength(), length: 0)
        return TypstResolvedCompletionInsertion(text: output, selectionRange: selection)
    }
}

public enum TypstCompletionRanking {
    public static func filteredAndSorted(_ items: [TypstCompletionItem], typedPrefix: String) -> [TypstCompletionItem] {
        let query = normalized(typedPrefix)
        var ranked: [(score: Int, item: TypstCompletionItem)] = []
        for item in items {
            if query.isEmpty {
                ranked.append((score: 0, item: item))
                continue
            }

            let candidates = [item.filterText, item.label, item.insertText]
            let scores = candidates.compactMap { candidate in
                score(candidate: normalized(candidate), query: query)
            }
            if let bestScore = scores.min() {
                ranked.append((score: bestScore, item: item))
            }
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                if lhs.item.sortText != rhs.item.sortText {
                    return lhs.item.sortText.localizedStandardCompare(rhs.item.sortText) == .orderedAscending
                }
                return lhs.item.label.localizedStandardCompare(rhs.item.label) == .orderedAscending
            }
            .map(\.item)
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
            .lowercased()
    }

    private static func score(candidate: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard !candidate.isEmpty else { return nil }

        if candidate == query {
            return 0
        }
        if candidate.hasPrefix(query) {
            return 10 + candidate.count - query.count
        }

        let parts = candidate
            .split { character in
                character == "/" || character == "." || character == "-" || character == "_" || character == ":"
            }
            .map(String.init)
        if let bestPart = parts.filter({ $0.hasPrefix(query) }).map(\.count).min() {
            return 40 + bestPart - query.count
        }

        if let range = candidate.range(of: query) {
            return 80 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        return nil
    }
}

public struct TypstHoverInfo: Equatable, Codable, Sendable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

public struct TypstSignatureHelp: Equatable, Codable, Sendable {
    public var signatures: [TypstSignatureInformation]
    public var activeSignature: Int
    public var activeParameter: Int

    public init(signatures: [TypstSignatureInformation], activeSignature: Int = 0, activeParameter: Int = 0) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

public struct TypstSignatureInformation: Equatable, Codable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var documentation: String
    public var parameters: [TypstParameterInformation]

    public init(label: String, documentation: String = "", parameters: [TypstParameterInformation] = []) {
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
    }
}

public struct TypstParameterInformation: Equatable, Codable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var documentation: String

    public init(label: String, documentation: String = "") {
        self.label = label
        self.documentation = documentation
    }
}

public struct TypstProseRange: Equatable, Codable, Sendable {
    public var range: NSRange

    public init(range: NSRange) {
        self.range = range
    }
}

public struct TypstOutlineItem: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { range.location }
    public var title: String
    public var level: Int
    public var range: NSRange

    public init(title: String, level: Int, range: NSRange) {
        self.title = title
        self.level = level
        self.range = range
    }
}

public struct TypstFigureItem: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case figure
        case table
        case image
    }

    public var id: Int { range.location }
    public var title: String
    public var kind: Kind
    public var label: String
    public var range: NSRange

    public init(title: String, kind: Kind, label: String, range: NSRange) {
        self.title = title
        self.kind = kind
        self.label = label
        self.range = range
    }
}

public struct TypstReferenceUse: Equatable, Codable, Sendable, Identifiable {
    public var id: Int { range.location }
    public var range: NSRange

    public init(range: NSRange) {
        self.range = range
    }
}

public struct TypstReferenceGroup: Equatable, Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Where the `<label>` is defined, or `nil` for a dangling `@reference`.
    public var source: NSRange?
    public var uses: [TypstReferenceUse]

    public init(name: String, source: NSRange?, uses: [TypstReferenceUse]) {
        self.name = name
        self.source = source
        self.uses = uses
    }
}

public struct TypstDocumentSymbols: Equatable, Codable, Sendable {
    public var outline: [TypstOutlineItem]
    public var figures: [TypstFigureItem]
    public var references: [TypstReferenceGroup]

    public init(
        outline: [TypstOutlineItem] = [],
        figures: [TypstFigureItem] = [],
        references: [TypstReferenceGroup] = []
    ) {
        self.outline = outline
        self.figures = figures
        self.references = references
    }

    public static let empty = TypstDocumentSymbols()
}

public enum TypstSourceOffsetConverter {
    public static func utf8Offset(fromUTF16Offset utf16Offset: Int, in text: String) -> Int {
        let nsText = text as NSString
        let clampedUTF16Offset = min(max(0, utf16Offset), nsText.length)
        guard let stringIndex = Range(NSRange(location: 0, length: clampedUTF16Offset), in: text)?.upperBound else {
            return text.utf8.count
        }
        return text[..<stringIndex].utf8.count
    }

    public static func utf16Range(fromUTF8Start startUTF8: Int, endUTF8: Int, in text: String) -> NSRange {
        let lower = stringIndex(fromUTF8Offset: startUTF8, in: text)
        let upper = stringIndex(fromUTF8Offset: max(startUTF8, endUTF8), in: text)
        let location = text.utf16.distance(from: text.utf16.startIndex, to: lower.samePosition(in: text.utf16) ?? text.utf16.endIndex)
        let end = text.utf16.distance(from: text.utf16.startIndex, to: upper.samePosition(in: text.utf16) ?? text.utf16.endIndex)
        return NSRange(location: location, length: max(0, end - location))
    }

    private static func stringIndex(fromUTF8Offset offset: Int, in text: String) -> String.Index {
        let clamped = min(max(0, offset), text.utf8.count)
        var utf8Index = text.utf8.startIndex
        text.utf8.formIndex(&utf8Index, offsetBy: clamped)
        return utf8Index.samePosition(in: text) ?? text.endIndex
    }
}

public protocol TypstLanguageService: Sendable {
    func setDebugLoggingEnabled(_ isEnabled: Bool) async
    func setWorkspace(rootURL: URL, compileTarget: String) async
    func setPackageStorage(localPackagesURL: URL, packageCacheURL: URL) async
    func setPackageFilePaths(_ paths: [String]) async
    func updateFile(path: String, text: String) async
    func closeFile(path: String) async
    func diagnostics() async -> [TypstSourceDiagnostic]
    func completions(path: String, utf16Offset: Int) async -> [TypstCompletionItem]
    func hover(path: String, utf16Offset: Int) async -> TypstHoverInfo?
    func signatureHelp(path: String, utf16Offset: Int) async -> TypstSignatureHelp?
    func proseRanges(path: String, ignoringCommandsAndArguments: Bool) async -> [TypstProseRange]
    func documentSymbols(path: String) async -> TypstDocumentSymbols
}

public enum TypstLanguageServiceFactory {
    public static func make() -> any TypstLanguageService {
        #if canImport(TypesetTinymist)
        EmbeddedTinymistLanguageService()
        #else
        BasicTypstLanguageService()
        #endif
    }
}

#if canImport(TypesetTinymist)
import TypesetTinymist

final class EmbeddedRustWorkQueue: @unchecked Sendable {
    static let languageService = EmbeddedRustWorkQueue(label: "com.twarge.typeset.embedded-rust.language-service")
    static let rendering = EmbeddedRustWorkQueue(label: "com.twarge.typeset.embedded-rust.rendering")

    private let queue: DispatchQueue

    private init(label: String) {
        queue = DispatchQueue(label: label, qos: .default)
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    func enqueue(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

public actor EmbeddedTinymistLanguageService: TypstLanguageService {
    private let sessionAddress: UInt
    private var files: [String: String] = [:]
    private var packageFilePaths: Set<String> = []
    private var packageStorageConfigured = false

    public init() {
        sessionAddress = UInt(bitPattern: typeset_tinymist_session_create())
    }

    deinit {
        let sessionAddress = sessionAddress
        EmbeddedRustWorkQueue.languageService.enqueue {
            typeset_tinymist_session_destroy(OpaquePointer(bitPattern: sessionAddress))
        }
    }

    public func setDebugLoggingEnabled(_ isEnabled: Bool) async {
        _ = await call { session in
            typeset_tinymist_set_debug_logging(session, isEnabled ? 1 : 0)
        }
    }

    public func setWorkspace(rootURL: URL, compileTarget: String) async {
        let rootPath = rootURL.path
        TypstLanguageDebug.log("setWorkspace root=\(rootPath) target=\(compileTarget)")
        _ = await call { session in
            typeset_tinymist_set_workspace(session, rootPath, compileTarget)
        }
        await ensurePackageStorageConfigured()
    }

    public func setPackageStorage(localPackagesURL: URL, packageCacheURL: URL) async {
        let localPath = localPackagesURL.path
        let cachePath = packageCacheURL.path
        TypstLanguageDebug.log(
            "setPackageStorage local=\(localPath) exists=\(FileManager.default.fileExists(atPath: localPath)) cache=\(cachePath) exists=\(FileManager.default.fileExists(atPath: cachePath))"
        )
        _ = await call { session in
            typeset_tinymist_set_package_storage(session, localPath, cachePath)
        }
        packageStorageConfigured = true
    }

    public func setPackageFilePaths(_ paths: [String]) async {
        packageFilePaths = Set(paths)
        TypstLanguageDebug.log("setPackageFilePaths count=\(paths.count)")
    }

    public func updateFile(path: String, text: String) async {
        files[path] = text
        _ = await call { session in
            typeset_tinymist_update_file(session, path, text)
        }
    }

    public func closeFile(path: String) async {
        files[path] = nil
        _ = await call { session in
            typeset_tinymist_close_file(session, path)
        }
    }

    public func diagnostics() async -> [TypstSourceDiagnostic] {
        guard let data = await call({ session in
            typeset_tinymist_diagnostics(session)
        }).data(using: .utf8),
              let response = try? JSONDecoder().decode(FFIDiagnosticResponse.self, from: data) else {
            return []
        }
        return response.diagnostics.map {
            let text = files[$0.file] ?? ""
            return TypstSourceDiagnostic(
                file: $0.file,
                range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: $0.startUtf8, endUTF8: $0.endUtf8, in: text),
                severity: TypstDiagnosticSeverity(rawValue: $0.severity) ?? .error,
                message: $0.message
            )
        }
    }

    public func completions(path: String, utf16Offset: Int) async -> [TypstCompletionItem] {
        await ensurePackageStorageConfigured()
        let text = files[path] ?? ""
        TypstLanguageDebug.log("completion request path=\(path) utf16=\(utf16Offset) textLength=\((text as NSString).length)")
        if let pathContext = TypstCompletionPathSupport.context(in: text, at: utf16Offset) {
            let typedPathPrefix = (text as NSString).substring(with: pathContext.replacementRange)
            TypstLanguageDebug.log("completion Swift path-context kind=\(pathContext.kind) typed='\(typedPathPrefix)'")
            if typedPathPrefix.hasPrefix("@") == false {
                let completions = TypstCompletionPathSupport.completions(
                    paths: Array(packageFilePaths),
                    excluding: path,
                    context: pathContext
                )
                if !completions.isEmpty {
                    TypstLanguageDebug.log("completion Swift path-results count=\(completions.count) labels=\(TypstLanguageDebug.labels(completions))")
                    return completions
                }
                TypstLanguageDebug.log("completion Swift path-results empty; delegating to Rust")
            } else {
                TypstLanguageDebug.log("completion package spec prefix detected; delegating to Rust")
            }
        }

        let offset = TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: utf16Offset, in: text)
        let rawResponse = await call({ session in
            typeset_tinymist_completions(session, path, UInt32(max(0, offset)))
        })
        guard let data = rawResponse.data(using: .utf8),
              let response = try? JSONDecoder().decode(FFICompletionResponse.self, from: data) else {
            TypstLanguageDebug.log("completion Rust decode failed responsePrefix=\(String(rawResponse.prefix(240)))")
            return []
        }
        let completions = response.completions.map {
            let replacementRange = TypstSourceOffsetConverter.utf16Range(
                fromUTF8Start: $0.replaceStartUtf8,
                endUTF8: $0.replaceEndUtf8,
                in: text
            )
            return TypstCompletionItem(
                label: $0.label,
                detail: $0.detail,
                insertText: $0.insertText,
                insertTextFormat: TypstCompletionInsertTextFormat(rawValue: $0.insertTextFormat) ?? .plainText,
                replacementRange: replacementRange,
                filterText: $0.filterText,
                sortText: $0.sortText,
                documentation: $0.documentation,
                kind: $0.kind
            )
        }
        TypstLanguageDebug.log("completion Rust results count=\(completions.count) labels=\(TypstLanguageDebug.labels(completions))")
        return completions
    }

    public func hover(path: String, utf16Offset: Int) async -> TypstHoverInfo? {
        let text = files[path] ?? ""
        let offset = TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: utf16Offset, in: text)
        guard let data = await call({ session in
            typeset_tinymist_hover(session, path, UInt32(max(0, offset)))
        }).data(using: .utf8),
              let response = try? JSONDecoder().decode(FFIHoverResponse.self, from: data),
              let hover = response.hover else {
            return nil
        }
        return TypstHoverInfo(
            range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: hover.startUtf8, endUTF8: hover.endUtf8, in: text),
            text: hover.text
        )
    }

    public func signatureHelp(path: String, utf16Offset: Int) async -> TypstSignatureHelp? {
        await ensurePackageStorageConfigured()
        let text = files[path] ?? ""
        let offset = TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: utf16Offset, in: text)
        TypstLanguageDebug.log("signature request path=\(path) utf16=\(utf16Offset) utf8=\(offset)")
        let rawResponse = await call({ session in
            typeset_tinymist_signature_help(session, path, UInt32(max(0, offset)))
        })
        guard let data = rawResponse.data(using: .utf8),
              let response = try? JSONDecoder().decode(FFISignatureHelpResponse.self, from: data) else {
            let fallback = TypstSignatureHelpProvider.signatureHelp(in: text, utf16Offset: utf16Offset)
            TypstLanguageDebug.log("signature Rust decode failed; fallback=\(fallback?.signatures.first?.label ?? "none") responsePrefix=\(String(rawResponse.prefix(240)))")
            return fallback
        }
        guard let signatureHelp = response.signatureHelp else {
            let fallback = TypstSignatureHelpProvider.signatureHelp(in: text, utf16Offset: utf16Offset)
            TypstLanguageDebug.log("signature Rust none; fallback=\(fallback?.signatures.first?.label ?? "none")")
            return fallback
        }
        let result = TypstSignatureHelp(
            signatures: signatureHelp.signatures.map { signature in
                TypstSignatureInformation(
                    label: signature.label,
                    documentation: signature.documentation,
                    parameters: signature.parameters.map {
                        TypstParameterInformation(label: $0.label, documentation: $0.documentation)
                    }
                )
            },
            activeSignature: signatureHelp.activeSignature,
            activeParameter: signatureHelp.activeParameter
        )
        TypstLanguageDebug.log("signature Rust result=\(result.signatures.first?.label ?? "none") activeParameter=\(result.activeParameter)")
        return result
    }

    private func ensurePackageStorageConfigured() async {
        guard !packageStorageConfigured else { return }
        do {
            let packageStorage = try TypstPackageStorage.appSupportStorage()
            try packageStorage.createDirectories()
            await setPackageStorage(
                localPackagesURL: packageStorage.localPackagesURL,
                packageCacheURL: packageStorage.packageCacheURL
            )
            TypstLanguageDebug.log("package storage lazily configured")
        } catch {
            TypstLanguageDebug.log("package storage lazy configuration failed: \(error.localizedDescription)")
        }
    }

    public func proseRanges(path: String, ignoringCommandsAndArguments: Bool) async -> [TypstProseRange] {
        guard let data = await call({ session in
            typeset_tinymist_prose_ranges_with_options(
                session,
                path,
                ignoringCommandsAndArguments ? 1 : 0
            )
        }).data(using: .utf8),
              let response = try? JSONDecoder().decode(FFIProseRangeResponse.self, from: data) else {
            return []
        }
        let text = files[path] ?? ""
        return response.ranges.map {
            TypstProseRange(range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: $0.startUtf8, endUTF8: $0.endUtf8, in: text))
        }
    }

    public func documentSymbols(path: String) async -> TypstDocumentSymbols {
        guard let data = await call({ session in
            typeset_tinymist_document_symbols(session, path)
        }).data(using: .utf8),
              let response = try? JSONDecoder().decode(FFIDocumentSymbolsResponse.self, from: data) else {
            return .empty
        }
        let text = files[path] ?? ""
        let outline = response.outline.map {
            TypstOutlineItem(
                title: $0.title,
                level: $0.level,
                range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: $0.startUtf8, endUTF8: $0.endUtf8, in: text)
            )
        }
        let figures = response.figures.map {
            TypstFigureItem(
                title: $0.title,
                kind: TypstFigureItem.Kind(rawValue: $0.kind) ?? .figure,
                label: $0.label,
                range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: $0.startUtf8, endUTF8: $0.endUtf8, in: text)
            )
        }
        let references = response.references.map { group in
            TypstReferenceGroup(
                name: group.name,
                source: group.hasSource
                    ? TypstSourceOffsetConverter.utf16Range(fromUTF8Start: group.sourceStartUtf8, endUTF8: group.sourceEndUtf8, in: text)
                    : nil,
                uses: group.uses.map {
                    TypstReferenceUse(range: TypstSourceOffsetConverter.utf16Range(fromUTF8Start: $0.startUtf8, endUTF8: $0.endUtf8, in: text))
                }
            )
        }
        return TypstDocumentSymbols(outline: outline, figures: figures, references: references)
    }

    private func call(_ body: @escaping @Sendable (OpaquePointer?) -> UnsafeMutablePointer<CChar>?) async -> String {
        let sessionAddress = sessionAddress
        return await EmbeddedRustWorkQueue.languageService.run {
            let session = OpaquePointer(bitPattern: sessionAddress)
            guard let pointer = body(session) else { return "" }
            defer { typeset_tinymist_string_free(pointer) }
            return String(cString: pointer)
        }
    }
}

private struct FFIDiagnosticResponse: Decodable {
    var diagnostics: [FFIDiagnostic]
}

private struct FFIDiagnostic: Decodable {
    var file: String
    var startUtf8: Int
    var endUtf8: Int
    var severity: String
    var message: String

    enum CodingKeys: String, CodingKey {
        case file
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
        case severity
        case message
    }
}

private struct FFICompletionResponse: Decodable {
    var completions: [FFICompletion]
}

private struct FFICompletion: Decodable {
    var label: String
    var detail: String
    var insertText: String
    var insertTextFormat: String
    var replaceStartUtf8: Int
    var replaceEndUtf8: Int
    var filterText: String
    var sortText: String
    var documentation: String
    var kind: String

    enum CodingKeys: String, CodingKey {
        case label
        case detail
        case insertText = "insert_text"
        case insertTextFormat = "insert_text_format"
        case replaceStartUtf8 = "replace_start_utf8"
        case replaceEndUtf8 = "replace_end_utf8"
        case filterText = "filter_text"
        case sortText = "sort_text"
        case documentation
        case kind
    }
}

private struct FFIHoverResponse: Decodable {
    var hover: FFIHover?
}

private struct FFIHover: Decodable {
    var startUtf8: Int
    var endUtf8: Int
    var text: String

    enum CodingKeys: String, CodingKey {
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
        case text
    }
}

private struct FFISignatureHelpResponse: Decodable {
    var signatureHelp: FFISignatureHelp?

    enum CodingKeys: String, CodingKey {
        case signatureHelp = "signature_help"
    }
}

private struct FFISignatureHelp: Decodable {
    var signatures: [FFISignatureInformation]
    var activeSignature: Int
    var activeParameter: Int

    enum CodingKeys: String, CodingKey {
        case signatures
        case activeSignature = "active_signature"
        case activeParameter = "active_parameter"
    }
}

private struct FFISignatureInformation: Decodable {
    var label: String
    var documentation: String
    var parameters: [FFIParameterInformation]
}

private struct FFIParameterInformation: Decodable {
    var label: String
    var documentation: String
}

private struct FFIDocumentSymbolsResponse: Decodable {
    var outline: [FFIOutlineItem]
    var figures: [FFIFigureItem]
    var references: [FFIReferenceGroup]
}

private struct FFIReferenceGroup: Decodable {
    var name: String
    var hasSource: Bool
    var sourceStartUtf8: Int
    var sourceEndUtf8: Int
    var uses: [FFISymbolRange]

    enum CodingKeys: String, CodingKey {
        case name
        case hasSource = "has_source"
        case sourceStartUtf8 = "source_start_utf8"
        case sourceEndUtf8 = "source_end_utf8"
        case uses
    }
}

private struct FFISymbolRange: Decodable {
    var startUtf8: Int
    var endUtf8: Int

    enum CodingKeys: String, CodingKey {
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
    }
}

private struct FFIOutlineItem: Decodable {
    var title: String
    var level: Int
    var startUtf8: Int
    var endUtf8: Int

    enum CodingKeys: String, CodingKey {
        case title
        case level
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
    }
}

private struct FFIFigureItem: Decodable {
    var title: String
    var kind: String
    var label: String
    var startUtf8: Int
    var endUtf8: Int

    enum CodingKeys: String, CodingKey {
        case title
        case kind
        case label
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
    }
}

private struct FFIProseRangeResponse: Decodable {
    var ranges: [FFIProseRange]
}

private struct FFIProseRange: Decodable {
    var startUtf8: Int
    var endUtf8: Int

    enum CodingKeys: String, CodingKey {
        case startUtf8 = "start_utf8"
        case endUtf8 = "end_utf8"
    }
}
#endif

private enum TypstCompletionPathSupport {
    struct Context {
        var replacementRange: NSRange
        var kind: Kind
    }

    enum Kind {
        case image
        case typstSource
    }

    static func context(in text: String, at location: Int) -> Context? {
        let nsText = text as NSString
        let offset = min(max(0, location), nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: offset, length: 0))
        let prefixLength = max(0, offset - lineRange.location)
        let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLength))
        guard unescapedQuoteCount(in: linePrefix) % 2 == 1 else {
            return nil
        }
        guard let quoteRange = linePrefix.range(of: "\"", options: .backwards) else {
            return nil
        }

        let beforeQuote = String(linePrefix[..<quoteRange.lowerBound])
        let quoteOffset = (beforeQuote as NSString).length
        let kind: Kind
        if beforeQuote.contains("#image") {
            kind = .image
        } else if beforeQuote.contains("#include") || beforeQuote.contains("#import") {
            kind = .typstSource
        } else {
            return nil
        }

        let start = lineRange.location + quoteOffset + 1
        return Context(
            replacementRange: NSRange(location: start, length: max(0, offset - start)),
            kind: kind
        )
    }

    static func completions(paths: [String], excluding currentPath: String, context: Context) -> [TypstCompletionItem] {
        paths
            .filter { $0 != currentPath }
            .filter { path($0, matches: context.kind) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map {
                TypstCompletionItem(
                    label: $0,
                    detail: "Package File",
                    insertText: $0,
                    replacementRange: context.replacementRange,
                    filterText: $0,
                    sortText: $0,
                    documentation: "Insert a package-relative file path.",
                    kind: "file"
                )
            }
    }

    private static func path(_ path: String, matches kind: Kind) -> Bool {
        let lowercased = path.lowercased()
        switch kind {
        case .image:
            return ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "tif", "tiff"].contains {
                lowercased.hasSuffix(".\($0)")
            }
        case .typstSource:
            return lowercased.hasSuffix(".typ")
        }
    }

    private static func unescapedQuoteCount(in text: String) -> Int {
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
            if character == "\"" {
                count += 1
            }
        }
        return count
    }
}

private enum TypstSignatureHelpProvider {
    private struct CallContext {
        var functionName: String
        var activeParameter: Int
    }

    private static let signatures: [String: TypstSignatureInformation] = [
        "image": TypstSignatureInformation(
            label: "image(path, width: auto, height: auto, alt: none, fit: \"contain\", scaling: \"auto\")",
            documentation: "Embeds an image from the package.",
            parameters: [
                TypstParameterInformation(label: "path", documentation: "A package-relative image path."),
                TypstParameterInformation(label: "width", documentation: "The displayed width."),
                TypstParameterInformation(label: "height", documentation: "The displayed height."),
                TypstParameterInformation(label: "alt", documentation: "Alternative text for accessibility."),
                TypstParameterInformation(label: "fit", documentation: "How the image is fit into its box."),
                TypstParameterInformation(label: "scaling", documentation: "The image scaling mode."),
            ]
        ),
        "include": TypstSignatureInformation(
            label: "include(path)",
            documentation: "Includes another Typst source file.",
            parameters: [
                TypstParameterInformation(label: "path", documentation: "A package-relative Typst file path."),
            ]
        ),
        "figure": TypstSignatureInformation(
            label: "figure(body, caption: none, supplement: auto, numbering: none, kind: auto)",
            documentation: "Wraps content in a figure with optional captioning and numbering.",
            parameters: [
                TypstParameterInformation(label: "body", documentation: "The figure content."),
                TypstParameterInformation(label: "caption", documentation: "The figure caption."),
                TypstParameterInformation(label: "supplement", documentation: "The figure supplement."),
                TypstParameterInformation(label: "numbering", documentation: "The numbering pattern."),
                TypstParameterInformation(label: "kind", documentation: "The figure kind."),
            ]
        ),
        "table": TypstSignatureInformation(
            label: "table(columns: auto, rows: auto, gutter: 0pt, inset: auto, align: auto, fill: none, stroke: auto, ..children)",
            documentation: "Lays out cells in rows and columns.",
            parameters: [
                TypstParameterInformation(label: "columns", documentation: "Column sizing."),
                TypstParameterInformation(label: "rows", documentation: "Row sizing."),
                TypstParameterInformation(label: "gutter", documentation: "Spacing between cells."),
                TypstParameterInformation(label: "inset", documentation: "Cell padding."),
                TypstParameterInformation(label: "align", documentation: "Cell alignment."),
                TypstParameterInformation(label: "fill", documentation: "Cell fill."),
                TypstParameterInformation(label: "stroke", documentation: "Cell stroke."),
                TypstParameterInformation(label: "..children", documentation: "Cell contents."),
            ]
        ),
        "rect": TypstSignatureInformation(
            label: "rect(width: auto, height: auto, fill: none, stroke: auto, radius: 0pt, inset: 0pt, body)",
            documentation: "Draws a rectangle, optionally around content.",
            parameters: [
                TypstParameterInformation(label: "width"),
                TypstParameterInformation(label: "height"),
                TypstParameterInformation(label: "fill"),
                TypstParameterInformation(label: "stroke"),
                TypstParameterInformation(label: "radius"),
                TypstParameterInformation(label: "inset"),
                TypstParameterInformation(label: "body"),
            ]
        ),
        "text": TypstSignatureInformation(
            label: "text(font: auto, size: auto, weight: auto, style: normal, fill: auto, body)",
            documentation: "Styles text content.",
            parameters: [
                TypstParameterInformation(label: "font"),
                TypstParameterInformation(label: "size"),
                TypstParameterInformation(label: "weight"),
                TypstParameterInformation(label: "style"),
                TypstParameterInformation(label: "fill"),
                TypstParameterInformation(label: "body"),
            ]
        ),
        "link": TypstSignatureInformation(
            label: "link(dest, body)",
            documentation: "Links content to a URL, label, or location.",
            parameters: [
                TypstParameterInformation(label: "dest", documentation: "The link destination."),
                TypstParameterInformation(label: "body", documentation: "The linked content."),
            ]
        ),
    ]

    static func signatureHelp(in text: String, utf16Offset: Int) -> TypstSignatureHelp? {
        guard let context = callContext(in: text, utf16Offset: utf16Offset),
              let signature = signatures[context.functionName] else {
            return nil
        }
        let activeParameter = min(max(0, context.activeParameter), max(0, signature.parameters.count - 1))
        return TypstSignatureHelp(
            signatures: [signature],
            activeSignature: 0,
            activeParameter: activeParameter
        )
    }

    private static func callContext(in text: String, utf16Offset: Int) -> CallContext? {
        let nsText = text as NSString
        let offset = min(max(0, utf16Offset), nsText.length)
        guard offset > 0 else { return nil }

        var index = offset - 1
        var depth = 0
        var activeParameter = 0
        var inString = false
        var inRaw = false

        while index >= 0 {
            let character = nsText.character(at: index)

            if character == 34, !inRaw, !isEscapedQuote(in: nsText, at: index) {
                inString.toggle()
            } else if character == 96, !inString {
                inRaw.toggle()
            } else if !inString && !inRaw {
                if character == 41 {
                    depth += 1
                } else if character == 40 {
                    if depth == 0 {
                        return functionCall(beforeOpenParen: index, activeParameter: activeParameter, in: nsText)
                    }
                    depth -= 1
                } else if character == 44, depth == 0 {
                    activeParameter += 1
                }
            }

            if index == 0 {
                break
            }
            index -= 1
        }
        return nil
    }

    private static func functionCall(beforeOpenParen openParen: Int, activeParameter: Int, in nsText: NSString) -> CallContext? {
        var end = openParen
        while end > 0, isWhitespace(nsText.character(at: end - 1)) {
            end -= 1
        }
        var start = end
        while start > 0, isFunctionNameCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        guard end > start else { return nil }

        let functionName = nsText.substring(with: NSRange(location: start, length: end - start))
        if start > 0 {
            let previous = nsText.character(at: start - 1)
            guard previous == 35 || isWhitespace(previous) || previous == 40 || previous == 91 || previous == 123 || previous == 44 else {
                return nil
            }
        }
        return CallContext(functionName: functionName, activeParameter: activeParameter)
    }

    private static func isEscapedQuote(in nsText: NSString, at quoteIndex: Int) -> Bool {
        var slashCount = 0
        var index = quoteIndex - 1
        while index >= 0, nsText.character(at: index) == 92 {
            slashCount += 1
            if index == 0 {
                break
            }
            index -= 1
        }
        return slashCount % 2 == 1
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(character) ?? "\0")
    }

    private static func isFunctionNameCharacter(_ character: unichar) -> Bool {
        CharacterSet.alphanumerics.contains(UnicodeScalar(character) ?? "\0") || character == 95 || character == 45
    }
}

public actor BasicTypstLanguageService: TypstLanguageService {
    private var compileTarget = ""
    private var files: [String: String] = [:]
    private var packageFilePaths: Set<String> = []

    public init() {}

    public func setDebugLoggingEnabled(_ isEnabled: Bool) async {}

    public func setWorkspace(rootURL: URL, compileTarget: String) async {
        self.compileTarget = compileTarget
    }

    public func setPackageStorage(localPackagesURL: URL, packageCacheURL: URL) async {}

    public func setPackageFilePaths(_ paths: [String]) async {
        packageFilePaths = Set(paths)
    }

    public func updateFile(path: String, text: String) async {
        files[path] = text
    }

    public func closeFile(path: String) async {
        files[path] = nil
    }

    public func diagnostics() async -> [TypstSourceDiagnostic] {
        files.flatMap { path, text in
            Self.localDiagnostics(path: path, text: text)
        }
    }

    public func completions(path: String, utf16Offset: Int) async -> [TypstCompletionItem] {
        let text = files[path] ?? ""
        let nsText = text as NSString
        let offset = min(max(0, utf16Offset), nsText.length)
        if let pathContext = TypstCompletionPathSupport.context(in: text, at: offset) {
            return TypstCompletionPathSupport.completions(
                paths: Array(packageFilePaths.union(files.keys)),
                excluding: path,
                context: pathContext
            )
        }

        let prefix = nsText.substring(to: offset)
        let replacementRange = Self.completionReplacementRange(in: text, at: offset)
        let typedPrefix = nsText.substring(with: replacementRange)
        let commandItems: [(label: String, insertText: String, format: TypstCompletionInsertTextFormat)] = [
            ("image", "image($0)", .snippet),
            ("include", "include \"$0\"", .snippet),
            ("import", "import \"$0\"", .snippet),
            ("set", "set $0", .snippet),
            ("show", "show $0", .snippet),
            ("let", "let $0", .snippet),
            ("figure", "figure($0)", .snippet),
            ("table", "table($0)", .snippet),
            ("link", "link($0)", .snippet),
        ]
        let completions = commandItems.map { item in
            let isCodeContext = prefix.hasSuffix("#") || Self.typstCodeCompletionContext(in: text, at: replacementRange.location)
            let label = item.label
            let insertText = isCodeContext ? item.insertText : "#\(item.insertText)"
            return TypstCompletionItem(
                label: label,
                detail: "Typst",
                insertText: insertText,
                insertTextFormat: item.format,
                replacementRange: replacementRange,
                filterText: item.label,
                sortText: item.label,
                kind: "keyword"
            )
        }
        let isCodeContext = prefix.hasSuffix("#") || Self.typstCodeCompletionContext(in: text, at: replacementRange.location)
        let markupCompletions = isCodeContext ? [] : Self.markupSnippetCompletions(replacementRange: replacementRange)
        return TypstCompletionRanking.filteredAndSorted(completions + markupCompletions, typedPrefix: typedPrefix)
    }

    private static func markupSnippetCompletions(replacementRange: NSRange) -> [TypstCompletionItem] {
        let snippets: [(label: String, insertText: String, documentation: String)] = [
            ("expression", "#$0", "Variables, function calls, blocks, and more."),
            ("linebreak", "\\\n$0", "Insert a forced line break."),
            ("strong text", "*${1:strong}*", "Strongly emphasize content by increasing the font weight."),
            ("emphasized text", "_${1:emphasized}_", "Emphasize content by setting it in italic font style."),
            ("raw text", "`${1:text}`", "Display text verbatim in monospace."),
            ("code listing", "```${1:lang}\n${2:code}\n```", "Insert computer code with syntax highlighting."),
            ("hyperlink", "https://${1:example.com}", "Insert a URL."),
            ("label", "<${1:name}>", "Make the preceding element referenceable."),
            ("reference", "@${1:name}", "Insert a reference to a label."),
            ("heading", "= ${1:title}", "Insert a section heading."),
            ("list item", "- ${1:item}", "Insert a bullet list item."),
            ("enumeration item", "+ ${1:item}", "Insert a numbered list item."),
            ("enumeration item (numbered)", "${1:number}. ${2:item}", "Insert an explicitly numbered list item."),
            ("term list item", "/ ${1:term}: ${2:description}", "Insert an item of a term list."),
            ("math (inline)", "$${1:x}$", "Insert an inline mathematical equation."),
            ("math (block)", "$ ${1:sum_x^2} $", "Insert a block mathematical equation."),
        ]
        return snippets.map { item in
            TypstCompletionItem(
                label: item.label,
                detail: "Typst Markup",
                insertText: item.insertText,
                insertTextFormat: .snippet,
                replacementRange: replacementRange,
                filterText: item.label,
                sortText: "~\(item.label)",
                documentation: item.documentation,
                kind: "snippet"
            )
        }
    }

    private static func typstCodeCompletionContext(in text: String, at replacementLocation: Int) -> Bool {
        let nsText = text as NSString
        let location = min(max(0, replacementLocation), nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        let linePrefixLength = max(0, location - lineRange.location)
        let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: linePrefixLength))
        if linePrefix.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return true
        }
        if linePrefix.contains("#{") || linePrefix.contains("#[") || linePrefix.contains("#(") {
            return true
        }
        return linePrefix.reversed().first { !$0.isWhitespace }.map {
            "#.([{,:=".contains($0)
        } ?? false
    }

    public func hover(path: String, utf16Offset: Int) async -> TypstHoverInfo? {
        guard let text = files[path] else { return nil }
        let nsText = text as NSString
        let length = nsText.length
        guard utf16Offset >= 0, utf16Offset <= length else { return nil }

        var start = utf16Offset
        while start > 0, Self.isWordCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }

        var end = utf16Offset
        while end < length, Self.isWordCharacter(nsText.character(at: end)) {
            end += 1
        }

        guard end > start else { return nil }
        guard Self.isHoverCodeContext(in: nsText, at: start) else { return nil }
        let word = nsText.substring(with: NSRange(location: start, length: end - start))
        return TypstHoverInfo(range: NSRange(location: start, length: end - start), text: "Typst symbol `\(word)`")
    }

    public func signatureHelp(path: String, utf16Offset: Int) async -> TypstSignatureHelp? {
        TypstSignatureHelpProvider.signatureHelp(in: files[path] ?? "", utf16Offset: utf16Offset)
    }

    public func proseRanges(path: String, ignoringCommandsAndArguments: Bool) async -> [TypstProseRange] {
        guard let text = files[path] else { return [] }
        return Self.proseRanges(
            in: text,
            ignoringCommandsAndArguments: ignoringCommandsAndArguments
        )
        .map(TypstProseRange.init(range:))
    }

    public func documentSymbols(path: String) async -> TypstDocumentSymbols {
        .empty
    }

    private static func localDiagnostics(path: String, text: String) -> [TypstSourceDiagnostic] {
        var diagnostics: [TypstSourceDiagnostic] = []
        diagnostics += unmatchedDelimiterDiagnostics(path: path, text: text, opener: "(", closer: ")")
        diagnostics += unmatchedDelimiterDiagnostics(path: path, text: text, opener: "[", closer: "]")
        diagnostics += unmatchedDelimiterDiagnostics(path: path, text: text, opener: "{", closer: "}")
        return diagnostics
    }

    private static func unmatchedDelimiterDiagnostics(path: String, text: String, opener: Character, closer: Character) -> [TypstSourceDiagnostic] {
        var stack: [Int] = []
        let nsText = text as NSString
        for index in 0..<nsText.length {
            let character = Character(UnicodeScalar(nsText.character(at: index)) ?? "\0")
            if character == opener {
                stack.append(index)
            } else if character == closer {
                if stack.isEmpty {
                    return [TypstSourceDiagnostic(file: path, range: NSRange(location: index, length: 1), severity: .error, message: "Unmatched `\(closer)`.")]
                }
                _ = stack.removeLast()
            }
        }
        return stack.map {
            TypstSourceDiagnostic(file: path, range: NSRange(location: $0, length: 1), severity: .error, message: "Unmatched `\(opener)`.")
        }
    }

    private static func proseRanges(in text: String, ignoringCommandsAndArguments: Bool) -> [NSRange] {
        let nsText = text as NSString
        var ranges: [NSRange] = []

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, enclosingRange, _ in
            let line = nsText.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !(ignoringCommandsAndArguments && trimmed.hasPrefix("#")),
                  !trimmed.hasPrefix("//"),
                  !trimmed.hasPrefix("```") else {
                return
            }

            let prose = mutableProseSegments(
                line: line,
                lineOffset: lineRange.location,
                ignoringCommandsAndArguments: ignoringCommandsAndArguments
            )
            ranges.append(contentsOf: prose)
            _ = enclosingRange
        }

        return ranges
    }

    private static func mutableProseSegments(
        line: String,
        lineOffset: Int,
        ignoringCommandsAndArguments: Bool
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var segmentStart: Int?
        var inString = false
        var inBacktick = false
        var inMath = false
        let scalars = Array(line.unicodeScalars)
        var index = 0

        func closeSegment(at index: Int) {
            if let start = segmentStart, index > start {
                ranges.append(NSRange(location: lineOffset + start, length: index - start))
            }
            segmentStart = nil
        }

        while index < scalars.count {
            let scalar = scalars[index]
            let isBlocked: Bool
            if ignoringCommandsAndArguments && scalar == "#" && !inString && !inBacktick && !inMath {
                closeSegment(at: index)
                index = scanTypstCommand(in: scalars, from: index)
                continue
            } else if scalar == "\"" && !inBacktick {
                inString.toggle()
                isBlocked = true
            } else if scalar == "`" && !inString {
                inBacktick.toggle()
                isBlocked = true
            } else if scalar == "$" {
                inMath.toggle()
                isBlocked = true
            } else {
                isBlocked = inString || inBacktick || inMath || scalar == "#" || scalar == "@" || scalar == "<"
            }

            if isBlocked {
                closeSegment(at: index)
            } else if segmentStart == nil {
                segmentStart = index
            }
            index += 1
        }

        if let start = segmentStart, scalars.count > start {
            ranges.append(NSRange(location: lineOffset + start, length: scalars.count - start))
        }
        return ranges
    }

    private static func scanTypstCommand(in scalars: [Unicode.Scalar], from hashIndex: Int) -> Int {
        var index = skipWhitespace(in: scalars, from: hashIndex + 1)
        guard index < scalars.count else { return min(hashIndex + 1, scalars.count) }

        if scalars[index] == "{" {
            return scanBalanced(in: scalars, from: index, open: "{", close: "}")
        }

        let nameStart = index
        while index < scalars.count, isCommandNameScalar(scalars[index]) {
            index += 1
        }
        guard index > nameStart else { return min(hashIndex + 1, scalars.count) }

        while true {
            index = skipWhitespace(in: scalars, from: index)
            guard index < scalars.count else { return index }

            switch scalars[index] {
            case "(":
                index = scanBalanced(in: scalars, from: index, open: "(", close: ")")
            case "[":
                index = scanBalanced(in: scalars, from: index, open: "[", close: "]")
            case "{":
                index = scanBalanced(in: scalars, from: index, open: "{", close: "}")
            case "\"":
                index = scanQuotedString(in: scalars, from: index)
            case "`":
                index = scanBacktickString(in: scalars, from: index)
            default:
                return index
            }
        }
    }

    private static func scanBalanced(in scalars: [Unicode.Scalar], from start: Int, open: Unicode.Scalar, close: Unicode.Scalar) -> Int {
        var index = start
        var depth = 0
        while index < scalars.count {
            if scalars[index] == "\"" {
                index = scanQuotedString(in: scalars, from: index)
                continue
            }
            if scalars[index] == "`" {
                index = scanBacktickString(in: scalars, from: index)
                continue
            }
            if scalars[index] == open {
                depth += 1
            } else if scalars[index] == close {
                depth -= 1
                if depth == 0 {
                    return index + 1
                }
            }
            index += 1
        }
        return scalars.count
    }

    private static func scanQuotedString(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        var escaped = false
        while index < scalars.count {
            if escaped {
                escaped = false
            } else if scalars[index] == "\\" {
                escaped = true
            } else if scalars[index] == "\"" {
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    private static func scanBacktickString(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        while index < scalars.count {
            if scalars[index] == "`" {
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    private static func skipWhitespace(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, scalars[index].properties.isWhitespace {
            index += 1
        }
        return index
    }

    private static func isCommandNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar == "-" || scalar == "."
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        CharacterSet.alphanumerics.contains(UnicodeScalar(character) ?? "\0") || character == 95 || character == 45
    }

    private static func isHoverCodeContext(in nsText: NSString, at location: Int) -> Bool {
        let clampedLocation = min(max(0, location), nsText.length)
        let lineRange = nsText.lineRange(for: NSRange(location: clampedLocation, length: 0))
        let prefix = nsText.substring(with: NSRange(
            location: lineRange.location,
            length: clampedLocation - lineRange.location
        ))
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)

        if trimmedPrefix.hasPrefix("#") || trimmedPrefix.hasPrefix("//") {
            return true
        }
        if prefix.contains("#") || prefix.contains("@") {
            return true
        }

        var cursor = clampedLocation
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

    private static func completionReplacementRange(in text: String, at location: Int) -> NSRange {
        let nsText = text as NSString
        var start = min(max(0, location), nsText.length)
        while start > 0, isWordCharacter(nsText.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: min(max(0, location), nsText.length) - start)
    }

}

public enum TypstCompilerDiagnosticParser {
    public static func parse(_ message: String, defaultFile: String) -> [TypstSourceDiagnostic] {
        let conventional = conventionalDiagnostics(in: message)
        if !conventional.isEmpty {
            return conventional
        }

        let pretty = prettyDiagnostics(in: message)
        if !pretty.isEmpty {
            return pretty
        }

        _ = defaultFile
        return []
    }

    private static func conventionalDiagnostics(in message: String) -> [TypstSourceDiagnostic] {
        let nsMessage = message as NSString
        let pattern = #"(?m)(?:^|\s)([^:\n]+\.typ):(\d+):(\d+):\s*(?:(error|warning):\s*)?([^\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return regex.matches(in: message, range: NSRange(location: 0, length: nsMessage.length)).compactMap { match in
            guard match.numberOfRanges >= 6,
                  let fileRange = Range(match.range(at: 1), in: message),
                  let lineRange = Range(match.range(at: 2), in: message),
                  let columnRange = Range(match.range(at: 3), in: message),
                  let messageRange = Range(match.range(at: 5), in: message),
                  let line = Int(message[lineRange]),
                  let column = Int(message[columnRange]) else {
                return nil
            }

            return TypstSourceDiagnostic(
                file: String(message[fileRange]),
                range: NSRange(location: max(0, line - 1), length: max(0, column - 1)),
                severity: severity(from: match.range(at: 4), in: message),
                message: String(message[messageRange])
            )
        }
    }

    private static func prettyDiagnostics(in message: String) -> [TypstSourceDiagnostic] {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var diagnostics: [TypstSourceDiagnostic] = []
        var pendingSeverity: TypstDiagnosticSeverity = .error
        var pendingMessage = "Typst compilation failed."

        for line in lines {
            if let parsed = parseSeverityLine(line) {
                pendingSeverity = parsed.severity
                pendingMessage = parsed.message
                continue
            }

            guard let location = parsePrettyLocationLine(line) else { continue }
            diagnostics.append(TypstSourceDiagnostic(
                file: location.file,
                range: NSRange(location: max(0, location.line - 1), length: max(0, location.column - 1)),
                severity: pendingSeverity,
                message: pendingMessage
            ))
        }

        return diagnostics
    }

    private static func parseSeverityLine(_ line: String) -> (severity: TypstDiagnosticSeverity, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("warning:") {
            return (.warning, String(trimmed.dropFirst("warning:".count)).trimmingCharacters(in: .whitespaces))
        }
        if trimmed.hasPrefix("error:") {
            return (.error, String(trimmed.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func parsePrettyLocationLine(_ line: String) -> (file: String, line: Int, column: Int)? {
        let nsLine = line as NSString
        let pattern = #"^\s*[┌╭─\-\|]*\s*(?:─\s*)?(.+):(\d+):(\d+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
              match.numberOfRanges >= 4,
              let fileRange = Range(match.range(at: 1), in: line),
              let lineRange = Range(match.range(at: 2), in: line),
              let columnRange = Range(match.range(at: 3), in: line),
              let parsedLine = Int(line[lineRange]),
              let parsedColumn = Int(line[columnRange]) else {
            return nil
        }

        return (String(line[fileRange]), parsedLine, parsedColumn)
    }

    private static func severity(from range: NSRange, in message: String) -> TypstDiagnosticSeverity {
        if let severityRange = Range(range, in: message), message[severityRange] == "warning" {
            return .warning
        }
        return .error
    }
}

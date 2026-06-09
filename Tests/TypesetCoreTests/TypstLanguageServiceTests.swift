// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

@Test func sourceOffsetConversionHandlesNonASCIIText() {
    let text = "Hi α\n#let café = 1"
    let cafeLocation = (text as NSString).range(of: "café").location
    let utf8Offset = TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: cafeLocation, in: text)
    let roundTrip = TypstSourceOffsetConverter.utf16Range(
        fromUTF8Start: utf8Offset,
        endUTF8: utf8Offset + "café".utf8.count,
        in: text
    )

    #expect(roundTrip == (text as NSString).range(of: "café"))
}

@Test func basicLanguageServiceReportsDiagnostics() async {
    let service = BasicTypstLanguageService()

    await service.updateFile(path: "main.typ", text: "#let value = (1")
    let diagnostics = await service.diagnostics()

    #expect(diagnostics.contains {
        $0.file == "main.typ" &&
        $0.severity == .error &&
        $0.message.contains("Unmatched")
    })
}

@Test func languageServiceProseRangesExcludeQuotedText() async {
    let service = BasicTypstLanguageService()
    let text = "Spell prose but not \"mispelled string\" or `mispelled raw` here"

    await service.updateFile(path: "main.typ", text: text)
    let ranges = await service.proseRanges(path: "main.typ", ignoringCommandsAndArguments: true)
    let checkedText = ranges
        .map { (text as NSString).substring(with: $0.range) }
        .joined()

    #expect(checkedText.contains("Spell prose"))
    #expect(checkedText.contains(" here"))
    #expect(!checkedText.contains("mispelled string"))
    #expect(!checkedText.contains("mispelled raw"))
}

@Test func languageServiceProseRangesExcludeCommandInvocations() async {
    let service = BasicTypstLanguageService()
    let text = "Spell prose #link(\"https://example.com\")[mispelled argument] and catch typoo"

    await service.updateFile(path: "main.typ", text: text)
    let ranges = await service.proseRanges(path: "main.typ", ignoringCommandsAndArguments: true)
    let checkedText = ranges
        .map { (text as NSString).substring(with: $0.range) }
        .joined()

    #expect(checkedText.contains("Spell prose"))
    #expect(checkedText.contains("and catch typoo"))
    #expect(!checkedText.contains("link"))
    #expect(!checkedText.contains("mispelled argument"))
}

@Test func languageServiceProseRangesCanIncludeCommandInvocations() async {
    let service = BasicTypstLanguageService()
    let text = "Spell prose #link(\"https://example.com\")[mispelled argument] and catch typoo"

    await service.updateFile(path: "main.typ", text: text)
    let ranges = await service.proseRanges(path: "main.typ", ignoringCommandsAndArguments: false)
    let checkedText = ranges
        .map { (text as NSString).substring(with: $0.range) }
        .joined()

    #expect(checkedText.contains("Spell prose"))
    #expect(checkedText.contains("link"))
    #expect(checkedText.contains("mispelled argument"))
    #expect(checkedText.contains("and catch typoo"))
}

@Test func basicLanguageServiceCompletesImagePaths() async {
    let service = BasicTypstLanguageService()
    await service.setPackageFilePaths(["main.typ", "Images/Atom.svg", "chapters/intro.typ"])
    await service.updateFile(path: "main.typ", text: "#image(\"Im\")")

    let completions = await service.completions(path: "main.typ", utf16Offset: 10)

    #expect(completions.map(\.label) == ["Images/Atom.svg"])
    #expect(completions.first?.replacementRange == NSRange(location: 8, length: 2))
}

@Test func basicLanguageServiceCompletesTypstIncludePaths() async {
    let service = BasicTypstLanguageService()
    await service.setPackageFilePaths(["main.typ", "Images/Atom.svg", "chapters/intro.typ"])
    await service.updateFile(path: "main.typ", text: "#include \"chap\"")

    let completions = await service.completions(path: "main.typ", utf16Offset: 14)

    #expect(completions.map(\.label) == ["chapters/intro.typ"])
    #expect(completions.first?.replacementRange == NSRange(location: 10, length: 4))
}

@Test func basicLanguageServiceFiltersCommandCompletionsByTypedPrefix() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "#im")

    let completions = await service.completions(path: "main.typ", utf16Offset: 3)

    #expect(completions.map(\.label) == ["image", "import"])
    #expect(completions.first?.insertText == "image($0)")
    #expect(completions.first?.insertTextFormat == .snippet)
    #expect(completions.first?.replacementRange == NSRange(location: 1, length: 2))
}

@Test func completionRankingUsesPrefixBeforeContains() {
    let completions = [
        TypstCompletionItem(label: "show", sortText: "show"),
        TypstCompletionItem(label: "image", sortText: "image"),
        TypstCompletionItem(label: "import", sortText: "import"),
    ]

    let ranked = TypstCompletionRanking.filteredAndSorted(completions, typedPrefix: "im")

    #expect(ranked.map(\.label) == ["image", "import"])
}

@Test func completionSnippetResolvesCursorTabStop() {
    let resolved = TypstCompletionSnippet.resolve("#image($0)", format: .snippet)

    #expect(resolved.text == "#image()")
    #expect(resolved.selectionRange == NSRange(location: 7, length: 0))
}

@Test func completionSnippetSelectsFirstPlaceholderText() {
    let resolved = TypstCompletionSnippet.resolve(#"include "${1:file.typ}"$0"#, format: .snippet)

    #expect(resolved.text == #"include "file.typ""#)
    #expect(resolved.selectionRange == NSRange(location: 9, length: 8))
}

@Test func basicLanguageServiceShowsSignatureHelpForFunctionArguments() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "#image(\"Images/Atom.svg\", width: 40%)")

    let help = await service.signatureHelp(path: "main.typ", utf16Offset: 27)

    #expect(help?.signatures.first?.label.hasPrefix("image(") == true)
    #expect(help?.activeParameter == 1)
    #expect(help?.signatures.first?.parameters[1].label == "width")
}

@Test func basicLanguageServiceShowsSignatureHelpForNestedCalls() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "#figure(image(\"a.svg\"), caption: [Atom])")

    let help = await service.signatureHelp(path: "main.typ", utf16Offset: 30)

    #expect(help?.signatures.first?.label.hasPrefix("figure(") == true)
    #expect(help?.activeParameter == 1)
    #expect(help?.signatures.first?.parameters[1].label == "caption")
}

@Test func basicLanguageServiceSuppressesPlainTextSymbolHover() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "This is plain text")

    let hover = await service.hover(path: "main.typ", utf16Offset: 11)

    #expect(hover == nil)
}

@Test func basicLanguageServiceShowsCommandSymbolHover() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "#image(\"a.svg\")")

    let hover = await service.hover(path: "main.typ", utf16Offset: 3)

    #expect(hover?.text == "Typst symbol `image`")
}

@Test func compilerDiagnosticParserReadsTypstPrettyDiagnostics() {
    let message = """
    error: expected expression
      ┌─ main.typ:3:12
      │
    3 │ #let value =
      │             ^
    """

    let diagnostics = TypstCompilerDiagnosticParser.parse(message, defaultFile: "main.typ")

    #expect(diagnostics.count == 1)
    #expect(diagnostics.first?.file == "main.typ")
    #expect(diagnostics.first?.range == NSRange(location: 2, length: 11))
    #expect(diagnostics.first?.severity == .error)
    #expect(diagnostics.first?.message == "expected expression")
}

@Test func compilerDiagnosticParserReadsConventionalDiagnostics() {
    let message = "main.typ:4:2: warning: something odd"

    let diagnostics = TypstCompilerDiagnosticParser.parse(message, defaultFile: "main.typ")

    #expect(diagnostics.count == 1)
    #expect(diagnostics.first?.file == "main.typ")
    #expect(diagnostics.first?.range == NSRange(location: 3, length: 1))
    #expect(diagnostics.first?.severity == .warning)
    #expect(diagnostics.first?.message == "something odd")
}

@Test func tinymistWorkspaceStoreMaterializesAndUpdatesFiles() async throws {
    let store = TinymistWorkspaceStore()
    let documentID = "TypesetTinymistStore-\(UUID().uuidString)"
    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= First".utf8)),
        PackageFile(path: "assets/readme.txt", data: Data("asset".utf8)),
    ])

    let documentRoot = try await store.materialize(package: package, documentID: documentID)
    defer { try? FileManager.default.removeItem(at: documentRoot) }
    _ = try await store.updateFile(documentID: documentID, path: "main.typ", data: Data("= Second".utf8))

    let updated = try String(contentsOf: documentRoot.appending(path: "main.typ"), encoding: .utf8)
    #expect(updated == "= Second")
    #expect(FileManager.default.fileExists(atPath: documentRoot.appending(path: "assets/readme.txt").path))
}

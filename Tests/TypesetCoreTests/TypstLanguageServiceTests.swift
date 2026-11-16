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

@Test func languageServiceProseRangesExcludeCommandSyntaxButIncludeContentArguments() async {
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
    #expect(!checkedText.contains("https://example.com"))
    #expect(checkedText.contains("mispelled argument"))
}

@Test func languageServiceProseRangesIncludeFigureContentArgument() async {
    let service = BasicTypstLanguageService()
    let text = "#figure([This is bhad rheally.])"

    await service.updateFile(path: "main.typ", text: text)
    let ranges = await service.proseRanges(path: "main.typ", ignoringCommandsAndArguments: true)
    let checkedText = ranges
        .map { (text as NSString).substring(with: $0.range) }
        .joined()

    #expect(checkedText == "This is bhad rheally.")
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

@Test func languageServiceProseRangesAlwaysExcludeSelectiveImports() async {
    let service = BasicTypstLanguageService()
    let text = "#import \"@preview/unify:0.8.1\": num,qty,numrange,qtyrange"

    await service.updateFile(path: "main.typ", text: text)
    for ignoreCommands in [false, true] {
        let ranges = await service.proseRanges(
            path: "main.typ",
            ignoringCommandsAndArguments: ignoreCommands
        )
        #expect(ranges.isEmpty)
    }
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
    #expect(help?.activeParameter == 8)
    #expect(help?.signatures.first?.parameters[8].label == "width")
}

@Test func basicLanguageServiceShowsSignatureHelpForNestedCalls() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "#figure(image(\"a.svg\"), caption: [Atom])")

    let help = await service.signatureHelp(path: "main.typ", utf16Offset: 30)

    #expect(help?.signatures.first?.label.hasPrefix("figure(") == true)
    #expect(help?.activeParameter == 1)
    #expect(help?.signatures.first?.parameters[1].label == "caption")
}

@Test func basicLanguageServiceNamesTheCallItsSignatureHelpDescribes() async {
    let service = BasicTypstLanguageService()
    let text = "#figure(image(\"a.svg\"), caption: [Atom])"
    await service.updateFile(path: "main.typ", text: text)

    let outer = await service.signatureHelp(path: "main.typ", utf16Offset: 30)
    let inner = await service.signatureHelp(path: "main.typ", utf16Offset: 14)

    #expect(outer?.callLocation == (text as NSString).range(of: "figure(").upperBound - 1)
    #expect(inner?.callLocation == (text as NSString).range(of: "image(").upperBound - 1)
}

@Test func helpSubjectIsTheCallForSignatureHelpAndForItsCalleeName() {
    let text = "#figure(image(\"a.svg\"), caption: [Atom])"
    let ns = text as NSString
    let figureParen = ns.range(of: "figure(").upperBound - 1
    let signature = TypstSignatureHelp(
        signatures: [TypstSignatureInformation(label: "figure(body)")],
        callLocation: figureParen
    )
    let hover = TypstHoverInfo(range: ns.range(of: "figure"), text: "A figure.")

    // Among the arguments it is signature help; on the name, the reference.
    // Both are help for the one call.
    #expect(TypstHelpSubject(signature: signature, hover: nil, caret: 30, in: text) == .call(openParen: figureParen))
    #expect(TypstHelpSubject(signature: nil, hover: hover, caret: 3, in: text) == .call(openParen: figureParen))
    #expect(TypstHelpSubject(signature: nil, hover: nil, caret: 3, in: text) == nil)
}

@Test func helpSubjectFallsBackToTheLineAndTheSymbol() {
    let text = "Intro\n#import \"utils.typ\": rect\n#let size = total"
    let ns = text as NSString
    let keyword = TypstSignatureHelp(signatures: [TypstSignatureInformation(label: "#import \"utils.typ\": rect")])
    let importLine = ns.range(of: "#import").location
    let total = ns.range(of: "total")
    let hover = TypstHoverInfo(range: total, text: "A length.")

    let line = TypstHelpSubject(signature: keyword, hover: nil, caret: ns.range(of: "rect").location, in: text)
    #expect(line == .line(start: importLine))
    #expect(line?.contains(caret: importLine + 3, in: text) == true)
    #expect(line?.contains(caret: 2, in: text) == false)

    let symbol = TypstHelpSubject(signature: nil, hover: hover, caret: total.location + 2, in: text)
    #expect(symbol == .symbol(total))
    #expect(symbol?.contains(caret: total.upperBound, in: text) == true)
    #expect(symbol?.contains(caret: total.location - 2, in: text) == false)
}

@Test func helpSubjectCallContainsItsNameAndArgumentsOnly() {
    let text = "#figure(image(\"a) .svg\"), caption: [Atom]) and #figure(rect())"
    let ns = text as NSString
    let figureParen = ns.range(of: "figure(").upperBound - 1
    let imageParen = ns.range(of: "image(").upperBound - 1
    let figure = TypstHelpSubject.call(openParen: figureParen)
    let closing = ns.range(of: "[Atom])").upperBound - 1

    // On the callee name, and just before the parenthesis.
    #expect(figure.contains(caret: 1, in: text))
    #expect(figure.contains(caret: figureParen, in: text))
    #expect(!figure.contains(caret: 0, in: text))
    // Among the arguments — a nested call's included, and a `)` inside a
    // string is not the call's own.
    #expect(figure.contains(caret: figureParen + 1, in: text))
    #expect(figure.contains(caret: imageParen + 4, in: text))
    #expect(figure.contains(caret: closing, in: text))
    // Past the closing parenthesis, and in another call of the same function.
    #expect(!figure.contains(caret: closing + 1, in: text))
    #expect(!figure.contains(caret: ns.length - 1, in: text))

    // The nested call ends at its own parenthesis, still inside the outer one.
    let image = TypstHelpSubject.call(openParen: imageParen)
    let afterImage = ns.range(of: ", caption").location
    #expect(image.contains(caret: afterImage - 1, in: text))
    #expect(!image.contains(caret: afterImage, in: text))
    #expect(figure.contains(caret: afterImage, in: text))
}

@Test func helpSubjectCallContainsItsWholeDottedName() {
    let text = "#let m = calc.max(1, 2) + (3)"
    let ns = text as NSString
    let subject = TypstHelpSubject.call(openParen: ns.range(of: "max(").upperBound - 1)

    #expect(subject.contains(caret: ns.range(of: "calc").location, in: text))
    #expect(subject.contains(caret: ns.range(of: "max").location + 1, in: text))
    #expect(!subject.contains(caret: ns.range(of: "calc").location - 1, in: text))
    // A parenthesis no name leads up to is not a call to be on the name of.
    let group = TypstHelpSubject.call(openParen: ns.range(of: "(3").location)
    #expect(!group.contains(caret: ns.range(of: "(3").location, in: text))
    #expect(group.contains(caret: ns.range(of: "(3").location + 1, in: text))
}

@Test func helpSubjectCallLapsesWhenItsParenthesisMoves() {
    let before = "#text(fill: red)"
    let paren = (before as NSString).range(of: "(").location
    let subject = TypstHelpSubject.call(openParen: paren)

    // Typing among the arguments leaves the parenthesis where it was…
    #expect(subject.contains(caret: 16, in: "#text(fill: red, size: 1)"))
    // …while an edit ahead of it moves it, which reads as having left.
    #expect(!subject.contains(caret: 12, in: "= #text(fill: red)"))
    #expect(!subject.contains(caret: 40, in: before))
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

#if canImport(TypesetLang)
@Test func embeddedLanguageServiceReturnsCodeActionsWithUTF16Edits() async {
    let service = EmbeddedLanguageService()
    let text = "α\n== Details"
    let caret = (text as NSString).range(of: "Details").location
    await service.updateFile(path: "main.typ", text: text)

    let actions = await service.codeActions(
        path: "main.typ",
        range: NSRange(location: caret, length: 0)
    )

    #expect(actions.map(\.title) == [
        "Decrease depth of heading",
        "Increase depth of heading",
    ])
    #expect(actions.first?.edit.range == (text as NSString).range(of: "=="))
    #expect(actions.first?.edit.text == "=")
}

@Test func embeddedLanguageServiceReturnsCrossFileRenameEditsInUTF16() async {
    let service = EmbeddedLanguageService()
    let main = "α\n#import \"defs.typ\": greet\n#greet(\"Ada\")"
    let defs = "#let greet(name) = [Hello #name]"
    await service.updateFile(path: "main.typ", text: main)
    await service.updateFile(path: "defs.typ", text: defs)
    let caret = (main as NSString).range(of: "greet", options: .backwards).location + 2

    let preparation = await service.prepareRename(path: "main.typ", utf16Offset: caret)
    let edit = await service.rename(path: "main.typ", utf16Offset: caret, newName: "welcome")

    #expect(preparation?.placeholder == "greet")
    #expect(preparation?.range == (main as NSString).range(of: "greet", options: .backwards))
    #expect(edit?.files.map(\.path).sorted() == ["defs.typ", "main.typ"])
    #expect(edit?.files.first(where: { $0.path == "main.typ" })?.edits.count == 2)
}

@Test func embeddedLanguageServiceReportsTheCallLocationInUTF16() async {
    let service = EmbeddedLanguageService()
    let text = "Café 😀 #image(\"plot.svg\") #image(\"other.svg\", width: 50%)"
    let ns = text as NSString
    let first = ns.range(of: "image(").upperBound - 1
    let second = ns.range(of: "image(", options: .backwards).upperBound - 1
    await service.updateFile(path: "main.typ", text: text)

    // Inside the string argument, where the caret usually is.
    let inFirst = await service.signatureHelp(path: "main.typ", utf16Offset: first + 4)
    let inSecond = await service.signatureHelp(path: "main.typ", utf16Offset: ns.range(of: "width").location)
    let keyword = await service.signatureHelp(path: "main.typ", utf16Offset: 2)

    #expect(inFirst?.signatures.first?.label.hasPrefix("image(") == true)
    #expect(inFirst?.callLocation == first)
    #expect(inSecond?.callLocation == second)
    #expect(keyword == nil)
}

@Test func embeddedLanguageServiceLeavesKeywordHelpWithoutACallLocation() async {
    let service = EmbeddedLanguageService()
    let text = "#import \"utils.typ\": rect"
    await service.updateFile(path: "main.typ", text: text)

    let help = await service.signatureHelp(path: "main.typ", utf16Offset: (text as NSString).length)

    #expect(help?.signatures.isEmpty == false)
    #expect(help?.callLocation == nil)
}

@Test func embeddedLanguageServiceReturnsNestedSelectionRangesInUTF16() async {
    let service = EmbeddedLanguageService()
    let text = "α #let value = image(\"plot.svg\")"
    await service.updateFile(path: "main.typ", text: text)
    let stringRange = (text as NSString).range(of: "\"plot.svg\"")
    let caret = stringRange.location + 4

    let ranges = await service.selectionRanges(
        path: "main.typ",
        range: NSRange(location: caret, length: 0)
    )

    #expect(ranges.contains(stringRange))
    #expect(ranges.last == NSRange(location: 0, length: (text as NSString).length))
}
#endif

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

@Test func languageWorkspaceStoreMaterializesAndUpdatesFiles() async throws {
    let store = LanguageWorkspaceStore()
    let documentID = "TypesetLangStore-\(UUID().uuidString)"
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

@Test func sourceOffsetConversionIsExactInsideGraphemeClusters() {
    // The compiler's offsets are scalar-aligned, not character-aligned. Each
    // of these lands inside a Swift `Character`, where a lookup by character
    // fails — and a failed lookup used to mean "end of document".
    let crlf = "= Head\r\nbody text here"
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 0, endUTF8: 7, in: crlf) == NSRange(location: 0, length: 7))
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 7, endUTF8: 7, in: crlf) == NSRange(location: 7, length: 0))
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 7, in: crlf) == 7)

    let combining = "#x\u{301} tail text"
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 1, endUTF8: 2, in: combining) == NSRange(location: 1, length: 1))
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 2, endUTF8: 4, in: combining) == NSRange(location: 2, length: 1))
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 2, in: combining) == 2)

    // woman, zero-width joiner, girl: one character, three scalars.
    let family = "a\u{1F469}\u{200D}\u{1F467}b"
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 5, endUTF8: 8, in: family) == NSRange(location: 3, length: 1))
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 8, endUTF8: 12, in: family) == NSRange(location: 4, length: 2))
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 3, in: family) == 5)
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 4, in: family) == 8)

    let astral = "\u{1D465} = 1"
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 4, endUTF8: 5, in: astral) == NSRange(location: 2, length: 1))
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 2, in: astral) == 4)
}

@Test func sourceOffsetConversionClampsOffsetsThatFitNoPosition() {
    // Between the halves of a surrogate pair, and inside a multi-byte
    // scalar: both back up to the start of the scalar.
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 2, in: "a\u{1F469}b") == 1)
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 1, endUTF8: 2, in: "\u{E9}a") == NSRange(location: 0, length: 1))

    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: -5, in: "ab") == 0)
    #expect(TypstSourceOffsetConverter.utf8Offset(fromUTF16Offset: 99, in: "ab") == 2)
    #expect(TypstSourceOffsetConverter.utf16Range(fromUTF8Start: 100, endUTF8: 200, in: "ab") == NSRange(location: 2, length: 0))
}

@Test func basicLanguageServiceProseRangesCountAstralCharactersInUTF16() async {
    let service = BasicTypstLanguageService()
    let text = "\u{1F600} Spell `raw` \u{1F600} tail"

    await service.updateFile(path: "main.typ", text: text)
    let ranges = await service.proseRanges(path: "main.typ", ignoringCommandsAndArguments: true)
    let checkedText = ranges
        .map { (text as NSString).substring(with: $0.range) }
        .joined()

    #expect(checkedText == "\u{1F600} Spell  \u{1F600} tail")
}

@Test func basicLanguageServiceLinebreakSnippetInsertsABackslash() async {
    let service = BasicTypstLanguageService()
    await service.updateFile(path: "main.typ", text: "linebreak")

    let completions = await service.completions(path: "main.typ", utf16Offset: 9)
    let linebreak = completions.first { $0.label == "linebreak" }
    let resolved = linebreak.map { TypstCompletionSnippet.resolve($0.insertText, format: $0.insertTextFormat) }

    // Typst's forced line break is a backslash at the end of the line.
    #expect(resolved?.text == "\\\n")
}

@Test func languageWorkspaceStoreClearsLeftoversAndRemovesItsOwn() async throws {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "TypesetLangStore-\(UUID().uuidString)", directoryHint: .isDirectory)
    let leftover = base.appending(path: "left-by-an-earlier-launch", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    try Data("= Stale".utf8).write(to: leftover.appending(path: "main.typ"))
    defer { try? FileManager.default.removeItem(at: base) }

    let package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= First".utf8)),
    ])

    // The first workspace of the process sweeps out what was there before.
    let store = LanguageWorkspaceStore(baseDirectory: base)
    let first = try await store.materialize(package: package, documentID: "first")
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(FileManager.default.fileExists(atPath: first.appending(path: "main.typ").path))

    // A second store — another document window — must not sweep the first
    // one's live workspace away.
    let otherStore = LanguageWorkspaceStore(baseDirectory: base)
    let second = try await otherStore.materialize(package: package, documentID: "second")
    #expect(FileManager.default.fileExists(atPath: first.appending(path: "main.typ").path))

    await store.remove(documentID: "first")
    #expect(!FileManager.default.fileExists(atPath: first.path))
    #expect(FileManager.default.fileExists(atPath: second.path))
}

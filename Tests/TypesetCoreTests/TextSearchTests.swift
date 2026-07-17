// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

@Test func literalSearchIsCaseInsensitiveByDefault() throws {
    let pattern = try TextSearchPattern(options: TextSearchOptions(query: "typeset"))
    let ranges = pattern.occurrences(in: "Typeset typeSET Typst").occurrences.map(\.range)

    #expect(ranges == [NSRange(location: 0, length: 7), NSRange(location: 8, length: 7)])
}

@Test func wholeWordSearchUsesUnicodeWordCharacters() throws {
    let pattern = try TextSearchPattern(options: TextSearchOptions(query: "cat", isWholeWord: true))
    let ranges = pattern.occurrences(in: "cat concatenate cat_ cat café-cat").occurrences.map(\.range)

    #expect(ranges == [
        NSRange(location: 0, length: 3),
        NSRange(location: 21, length: 3),
        NSRange(location: 30, length: 3),
    ])
}

@Test func regexSearchExpandsCaptureGroupsInReplacement() throws {
    let options = TextSearchOptions(query: "(\\w+),\\s*(\\w+)", usesRegularExpression: true)
    let pattern = try TextSearchPattern(options: options)
    let result = pattern.occurrences(in: "Kornack, David", replacementTemplate: "$2 $1")

    #expect(result.occurrences.first?.replacementText == "David Kornack")
    #expect(pattern.replacingAll(in: "Kornack, David", with: "$2 $1") == "David Kornack")
}

@Test func regexSearchHandlesZeroLengthMatches() throws {
    let pattern = try TextSearchPattern(options: TextSearchOptions(query: "(?=a)", usesRegularExpression: true))
    let result = pattern.occurrences(in: "aaa")

    #expect(result.occurrences.map(\.range) == [
        NSRange(location: 0, length: 0),
        NSRange(location: 1, length: 0),
        NSRange(location: 2, length: 0),
    ])
}

@Test func invalidRegexReturnsAReadableError() {
    #expect(throws: TextSearchPatternError.self) {
        try TextSearchPattern(options: TextSearchOptions(query: "(", usesRegularExpression: true))
    }
}

@Test func fileFiltersSupportBasenamesRecursiveGlobsAndExclusions() {
    let filter = TextSearchFileFilter(including: "*.typ, Images/**", excluding: "Tests/**, **/Draft.typ")

    #expect(filter.includes(path: "main.typ"))
    #expect(filter.includes(path: "Chapters/Intro.typ"))
    #expect(filter.includes(path: "Images/plot.svg"))
    #expect(!filter.includes(path: "notes.txt"))
    #expect(!filter.includes(path: "Tests/check.typ"))
    #expect(!filter.includes(path: "Chapters/Draft.typ"))
}

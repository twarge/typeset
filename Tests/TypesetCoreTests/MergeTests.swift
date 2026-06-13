// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

// MARK: - Deterministic pseudo-random source for fuzz tests

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private func makeLines(_ count: Int, prefix: String = "line") -> String {
    (0..<count).map { "\(prefix) \($0)" }.joined(separator: "\n") + "\n"
}

// MARK: - LineDiff

@Test func lineSplitRoundTripsTerminators() {
    let samples = [
        "",
        "no newline",
        "trailing\n",
        "a\nb\nc",
        "a\r\nb\r\n",
        "mixed\r\nunix\nlast",
        "\n\n\n",
    ]
    for sample in samples {
        #expect(LineDiff.splitLines(sample).joined() == sample)
    }
}

@Test func lineDiffMatchesAreStrictlyIncreasing() {
    let old = LineDiff.splitLines("a\nb\nc\nd\n")
    let new = LineDiff.splitLines("a\nx\nc\nd\ne\n")
    let matches = LineDiff.matches(old: old, new: new)
    for (left, right) in zip(matches, matches.dropFirst()) {
        #expect(left.old < right.old)
        #expect(left.new < right.new)
    }
    for match in matches {
        #expect(old[match.old] == new[match.new])
    }
}

// MARK: - ThreeWayMerge laws

@Test func mergeIdenticalSidesIsClean() {
    let base = makeLines(5)
    let result = ThreeWayMerge.merge(base: base, mine: base, theirs: base)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == base)
}

@Test func mergeOnlyMineChangedTakesMine() {
    let base = makeLines(5)
    let mine = base.replacingOccurrences(of: "line 2", with: "line 2 edited")
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: base)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == mine)
}

@Test func mergeOnlyTheirsChangedTakesTheirs() {
    let base = makeLines(5)
    let theirs = base.replacingOccurrences(of: "line 3", with: "line 3 remote")
    let result = ThreeWayMerge.merge(base: base, mine: base, theirs: theirs)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == theirs)
}

@Test func mergeNonOverlappingEditsContainsBoth() {
    let base = makeLines(10)
    let mine = base.replacingOccurrences(of: "line 1", with: "line 1 local")
    let theirs = base.replacingOccurrences(of: "line 8", with: "line 8 remote")
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine.contains("line 1 local"))
    #expect(result.mergedKeepingMine.contains("line 8 remote"))
}

@Test func mergeIdenticalChangesOnBothSidesIsClean() {
    let base = makeLines(6)
    let changed = base.replacingOccurrences(of: "line 4", with: "line 4 same-change")
    let result = ThreeWayMerge.merge(base: base, mine: changed, theirs: changed)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == changed)
}

@Test func mergeOverlappingEditsConflict() {
    let base = makeLines(5)
    let mine = base.replacingOccurrences(of: "line 2", with: "line 2 local")
    let theirs = base.replacingOccurrences(of: "line 2", with: "line 2 remote")
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    #expect(!result.isClean)
    #expect(result.conflicts.count == 1)
    #expect(result.conflicts[0].mineText.contains("local"))
    #expect(result.conflicts[0].theirsText.contains("remote"))
    #expect(result.mergedKeepingMine == mine)
    let theirsResolved = result.resolved(choices: [result.conflicts[0].id: .theirs])
    #expect(theirsResolved == theirs)
}

@Test func mergeBothAppendDifferentTailsConflicts() {
    let base = "shared\n"
    let mine = "shared\nmine tail\n"
    let theirs = "shared\ntheirs tail\n"
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    #expect(!result.isClean)
    #expect(result.mergedKeepingMine == mine)
    #expect(result.resolved(choices: [result.conflicts[0].id: .theirs]) == theirs)
}

@Test func mergeDeletionAgainstUntouchedSideIsClean() {
    let base = makeLines(6)
    let mine = base.replacingOccurrences(of: "line 2\n", with: "")
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: base)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == mine)
}

@Test func mergeHandlesMissingTrailingNewline() {
    let base = "a\nb\nc"
    let mine = "a\nb edited\nc"
    let theirs = "a\nb\nc\nd"
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    #expect(result.mergedKeepingMine.contains("b edited"))
}

@Test func mergeHandlesCRLF() {
    let base = "a\r\nb\r\nc\r\n"
    let mine = "a\r\nb local\r\nc\r\n"
    let theirs = "a\r\nb\r\nc\r\nd\r\n"
    let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
    #expect(result.isClean)
    #expect(result.mergedKeepingMine == "a\r\nb local\r\nc\r\nd\r\n")
}

@Test func mergeFuzzConvergence() {
    var generator = SeededGenerator(seed: 0x7E5E)
    for _ in 0..<60 {
        let lineCount = Int.random(in: 8...40, using: &generator)
        let base = makeLines(lineCount)
        var baseLines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        baseLines.removeLast()  // trailing empty from final newline

        // Mine edits the first half, theirs edits the second half — always
        // disjoint, so the merge must be clean and contain both.
        var mineLines = baseLines
        var theirsLines = baseLines
        let half = lineCount / 2
        let mineIndex = Int.random(in: 0..<max(1, half - 1), using: &generator)
        let theirsIndex = Int.random(in: (half + 1)..<lineCount, using: &generator)
        mineLines[mineIndex] = "mine edit \(mineIndex)"
        theirsLines[theirsIndex] = "theirs edit \(theirsIndex)"

        let mine = mineLines.joined(separator: "\n") + "\n"
        let theirs = theirsLines.joined(separator: "\n") + "\n"
        let result = ThreeWayMerge.merge(base: base, mine: mine, theirs: theirs)
        #expect(result.isClean)
        #expect(result.mergedKeepingMine.contains("mine edit \(mineIndex)"))
        #expect(result.mergedKeepingMine.contains("theirs edit \(theirsIndex)"))
    }
}

// MARK: - TextEditScript

@Test func editScriptTransformsOldIntoNew() {
    let pairs: [(String, String)] = [
        ("", "hello\n"),
        ("hello\n", ""),
        ("a\nb\nc\n", "a\nB\nc\n"),
        ("a\nb\nc\n", "a\nc\n"),
        ("a\nc\n", "a\nb\nc\n"),
        ("same\n", "same\n"),
        ("x\ny\nz", "x\nY edited\nz\nw"),
        ("emoji 😀\nline\n", "emoji 😀!\nline\n"),
    ]
    for (old, new) in pairs {
        let edits = TextEditScript.edits(from: old, to: new)
        #expect(TextEditScript.apply(edits, to: old) == new, "\(old) -> \(new)")
    }
}

@Test func editScriptFuzzRoundTrip() {
    var generator = SeededGenerator(seed: 0xED17)
    for _ in 0..<80 {
        let count = Int.random(in: 1...30, using: &generator)
        var lines = (0..<count).map { "line \($0) content" }
        let old = lines.joined(separator: "\n") + "\n"
        let operations = Int.random(in: 1...5, using: &generator)
        for _ in 0..<operations where !lines.isEmpty {
            let index = Int.random(in: 0..<lines.count, using: &generator)
            switch Int.random(in: 0...2, using: &generator) {
            case 0: lines[index] = "edited \(Int.random(in: 0...999, using: &generator))"
            case 1: lines.remove(at: index)
            default: lines.insert("inserted \(Int.random(in: 0...999, using: &generator))", at: index)
            }
        }
        let new = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        let edits = TextEditScript.edits(from: old, to: new)
        #expect(TextEditScript.apply(edits, to: old) == new)
    }
}

@Test func editScriptRemapsCaretBeforeAndAfterEdit() {
    let old = "aaa\nbbb\nccc\n"
    let new = "aaa\nbbb edited\nccc\n"
    let edits = TextEditScript.edits(from: old, to: new)

    // Caret before the edit is untouched.
    let before = TextEditScript.remap(NSRange(location: 2, length: 0), through: edits)
    #expect(before == NSRange(location: 2, length: 0))

    // Caret after the edit shifts by the delta.
    let delta = new.utf16.count - old.utf16.count
    let after = TextEditScript.remap(NSRange(location: 10, length: 0), through: edits)
    #expect(after == NSRange(location: 10 + delta, length: 0))
}

@Test func editScriptClampsCaretInsideReplacedRegion() {
    let old = "aaa\nbbbbbbbb\nccc\n"
    let new = "aaa\nx\nccc\n"
    let edits = TextEditScript.edits(from: old, to: new)
    let remapped = TextEditScript.remap(NSRange(location: 8, length: 0), through: edits)
    #expect(remapped.location <= new.utf16.count)
    #expect(remapped.length == 0)
}

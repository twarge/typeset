// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A single ranged replacement, expressed in UTF-16 units of the text the
/// edit script was computed against (the editor's native coordinate space).
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Minimal edit scripts between two texts, used to apply remote changes to a
/// live text view as ranged replacements (preserving caret and scroll) rather
/// than wholesale text resets.
public enum TextEditScript {
    /// Edits that transform `old` into `new`: line-diff regions refined by
    /// trimming common prefix/suffix characters. Sorted ascending and
    /// non-overlapping.
    public static func edits(from old: String, to new: String) -> [TextEdit] {
        if old == new { return [] }

        let oldLines = LineDiff.splitLines(old)
        let newLines = LineDiff.splitLines(new)
        let matches = LineDiff.matches(old: oldLines, new: newLines)

        // UTF-16 offsets of each old line start.
        var oldOffsets: [Int] = [0]
        oldOffsets.reserveCapacity(oldLines.count + 1)
        for line in oldLines {
            oldOffsets.append(oldOffsets[oldOffsets.count - 1] + line.utf16.count)
        }

        var edits: [TextEdit] = []
        var i = 0
        var j = 0

        func appendEdit(oldRange: Range<Int>, newRange: Range<Int>) {
            let oldText = oldLines[oldRange].joined()
            let newText = newLines[newRange].joined()
            guard oldText != newText else { return }
            // Trim common prefix/suffix at character (grapheme) boundaries so
            // the replacement is minimal and never splits surrogate pairs.
            var oldSub = Substring(oldText)
            var newSub = Substring(newText)
            while let o = oldSub.first, let n = newSub.first, o == n {
                oldSub = oldSub.dropFirst()
                newSub = newSub.dropFirst()
            }
            while let o = oldSub.last, let n = newSub.last, o == n {
                oldSub = oldSub.dropLast()
                newSub = newSub.dropLast()
            }
            let trimmedPrefix = oldText[..<oldSub.startIndex].utf16.count
            let location = oldOffsets[oldRange.lowerBound] + trimmedPrefix
            edits.append(TextEdit(
                range: NSRange(location: location, length: String(oldSub).utf16.count),
                replacement: String(newSub)
            ))
        }

        for match in matches {
            if match.old > i || match.new > j {
                appendEdit(oldRange: i..<match.old, newRange: j..<match.new)
            }
            i = match.old + 1
            j = match.new + 1
        }
        if i < oldLines.count || j < newLines.count {
            appendEdit(oldRange: i..<oldLines.count, newRange: j..<newLines.count)
        }
        return edits
    }

    /// Applies `edits` (computed against `text`) and returns the result.
    public static func apply(_ edits: [TextEdit], to text: String) -> String {
        let mutable = NSMutableString(string: text)
        for edit in edits.reversed() {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    /// Remaps a selection through `edits` so a caret keeps pointing at the
    /// same logical spot after the edits apply. A selection inside a replaced
    /// region clamps to the replacement's end.
    public static func remap(_ selection: NSRange, through edits: [TextEdit]) -> NSRange {
        var location = selection.location
        var end = selection.location + selection.length

        for edit in edits {
            let delta = edit.replacement.utf16.count - edit.range.length
            let editEnd = edit.range.location + edit.range.length

            if editEnd <= location {
                location += delta
                end += delta
            } else if edit.range.location >= end {
                break
            } else {
                // Overlap: clamp into the replacement.
                let replacementEnd = edit.range.location + edit.replacement.utf16.count
                if location > edit.range.location {
                    location = min(location + delta, replacementEnd)
                }
                end = min(max(end + delta, location), max(replacementEnd, location))
            }
        }
        return NSRange(location: max(0, location), length: max(0, end - location))
    }
}

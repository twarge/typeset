// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Line-level diff built on the Myers O(ND) algorithm. Lines retain their
/// terminators so that joining any slice reproduces the original text
/// byte-for-byte (mixed LF/CRLF and missing trailing newlines round-trip).
public enum LineDiff {
    /// Splits `text` into lines, each keeping its terminator. The final line
    /// has no terminator when the text doesn't end with one.
    public static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines: [Substring] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            // "\r\n" is a single grapheme cluster in Swift, so both checks
            // are needed to terminate lines for LF and CRLF content.
            let character = text[index]
            if character == "\n" || character == "\r\n" {
                let end = text.index(after: index)
                lines.append(text[start..<end])
                start = end
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        if start < text.endIndex {
            lines.append(text[start..<text.endIndex])
        }
        return lines
    }

    /// Indices of matching lines between `old` and `new`, strictly increasing
    /// on both sides — the longest common subsequence found by Myers.
    public static func matches(old: [Substring], new: [Substring]) -> [(old: Int, new: Int)] {
        // Hash lines first so comparisons are integer comparisons; equal
        // hashes fall back to string comparison to rule out collisions.
        let oldHashes = old.map(\.hashValue)
        let newHashes = new.map(\.hashValue)
        func equal(_ i: Int, _ j: Int) -> Bool {
            oldHashes[i] == newHashes[j] && old[i] == new[j]
        }

        let n = old.count
        let m = new.count
        if n == 0 || m == 0 { return [] }

        let max = n + m
        var v = [Int](repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []

        var found = false
        outer: for d in 0...max {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) {
                    x = v[max + k + 1]
                } else {
                    x = v[max + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, equal(x, y) {
                    x += 1
                    y += 1
                }
                v[max + k] = x
                if x >= n, y >= m {
                    found = true
                    break outer
                }
                k += 2
            }
        }
        guard found else { return [] }

        // Backtrack through the trace collecting diagonal (match) runs.
        var result: [(old: Int, new: Int)] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[max + k - 1] < v[max + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = v[max + prevK]
            let prevY = prevX - prevK
            while x > prevX, y > prevY {
                x -= 1
                y -= 1
                result.append((old: x, new: y))
            }
            if d > 0 {
                x = prevX
                y = prevY
            }
        }
        return result.reversed()
    }
}

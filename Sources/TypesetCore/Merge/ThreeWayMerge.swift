// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum MergeSide: Sendable, Hashable {
    case mine
    case theirs
}

/// One region where both sides changed the same base lines differently.
public struct MergeConflict: Identifiable, Equatable, Sendable {
    public var id: Int
    public var baseText: String
    public var mineText: String
    public var theirsText: String

    public init(id: Int, baseText: String, mineText: String, theirsText: String) {
        self.id = id
        self.baseText = baseText
        self.mineText = mineText
        self.theirsText = theirsText
    }
}

public struct MergeResult: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case merged(String)
        case conflict(MergeConflict)
    }

    public var segments: [Segment]

    public var conflicts: [MergeConflict] {
        segments.compactMap {
            if case .conflict(let conflict) = $0 { return conflict }
            return nil
        }
    }

    public var isClean: Bool { conflicts.isEmpty }

    /// The merged document with every conflict resolved toward `mine` — the
    /// safe default the editor holds while the user reviews conflicts.
    public var mergedKeepingMine: String {
        resolved { _ in .mine }
    }

    /// The merged document with per-conflict choices; conflicts absent from
    /// `choices` resolve toward `mine`.
    public func resolved(choices: [Int: MergeSide]) -> String {
        resolved { choices[$0.id] ?? .mine }
    }

    public func resolved(_ choose: (MergeConflict) -> MergeSide) -> String {
        var output = ""
        for segment in segments {
            switch segment {
            case .merged(let text):
                output += text
            case .conflict(let conflict):
                output += choose(conflict) == .mine ? conflict.mineText : conflict.theirsText
            }
        }
        return output
    }
}

/// Line-level three-way merge (diff3). Regions changed on only one side
/// merge automatically; regions changed identically on both sides merge
/// automatically; regions changed differently on both sides surface as
/// conflicts.
public enum ThreeWayMerge {
    public static func merge(base: String, mine: String, theirs: String) -> MergeResult {
        // Trivial fast paths.
        if mine == theirs {
            return MergeResult(segments: mine.isEmpty ? [] : [.merged(mine)])
        }
        if base == mine {
            return MergeResult(segments: theirs.isEmpty ? [] : [.merged(theirs)])
        }
        if base == theirs {
            return MergeResult(segments: mine.isEmpty ? [] : [.merged(mine)])
        }

        let baseLines = LineDiff.splitLines(base)
        let mineLines = LineDiff.splitLines(mine)
        let theirsLines = LineDiff.splitLines(theirs)

        var baseToMine: [Int: Int] = [:]
        for match in LineDiff.matches(old: baseLines, new: mineLines) {
            baseToMine[match.old] = match.new
        }
        var baseToTheirs: [Int: Int] = [:]
        for match in LineDiff.matches(old: baseLines, new: theirsLines) {
            baseToTheirs[match.old] = match.new
        }

        var segments: [MergeResult.Segment] = []
        var pendingMerged = ""
        var conflictID = 0

        func emitMerged<S: Sequence>(_ lines: S) where S.Element == Substring {
            for line in lines { pendingMerged += line }
        }

        func flushMerged() {
            if !pendingMerged.isEmpty {
                segments.append(.merged(pendingMerged))
                pendingMerged = ""
            }
        }

        var i = 0  // base cursor
        var j = 0  // mine cursor
        var k = 0  // theirs cursor

        while i < baseLines.count || j < mineLines.count || k < theirsLines.count {
            // Emit perfectly aligned stable lines.
            if i < baseLines.count, baseToMine[i] == j, baseToTheirs[i] == k {
                pendingMerged += baseLines[i]
                i += 1
                j += 1
                k += 1
                continue
            }

            // Divergence: find the next base line aligned in both diffs.
            var nextBase = i
            var resync: (base: Int, mine: Int, theirs: Int)?
            while nextBase < baseLines.count {
                if let m = baseToMine[nextBase], let t = baseToTheirs[nextBase], m >= j, t >= k {
                    resync = (nextBase, m, t)
                    break
                }
                nextBase += 1
            }
            let baseEnd = resync?.base ?? baseLines.count
            let mineEnd = resync?.mine ?? mineLines.count
            let theirsEnd = resync?.theirs ?? theirsLines.count

            let baseChunk = baseLines[i..<baseEnd].joined()
            let mineChunk = mineLines[j..<mineEnd].joined()
            let theirsChunk = theirsLines[k..<theirsEnd].joined()

            if mineChunk == theirsChunk {
                emitMerged(mineLines[j..<mineEnd])
            } else if mineChunk == baseChunk {
                emitMerged(theirsLines[k..<theirsEnd])
            } else if theirsChunk == baseChunk {
                emitMerged(mineLines[j..<mineEnd])
            } else {
                flushMerged()
                segments.append(.conflict(MergeConflict(
                    id: conflictID,
                    baseText: baseChunk,
                    mineText: mineChunk,
                    theirsText: theirsChunk
                )))
                conflictID += 1
            }

            i = baseEnd
            j = mineEnd
            k = theirsEnd
        }

        flushMerged()
        return MergeResult(segments: segments)
    }
}

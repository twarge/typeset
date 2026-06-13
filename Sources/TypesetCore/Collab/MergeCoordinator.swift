// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-file base tracking for a collaboration replica: pure value logic with
/// no transport dependency. The invariant is the plan's base-advance rule —
/// **the merge base advances only on convergence**: when a fetched remote
/// version is applied (possibly after merging) or when the server accepts a
/// local send. An offline gap therefore always yields the correct
/// (base, mine, theirs) triple on reconnect.
public struct MergeCoordinator: Equatable, Sendable {
    /// Last-converged text per file identifier.
    private var bases: [String: String]

    public init(bases: [String: String] = [:]) {
        self.bases = bases
    }

    public func base(for id: String) -> String? {
        bases[id]
    }

    /// Seeds or restores a base (initial share materialization, or loading
    /// a persisted base store across launches).
    public mutating func setBase(_ text: String, for id: String) {
        bases[id] = text
    }

    public mutating func removeBase(for id: String) {
        bases.removeValue(forKey: id)
    }

    /// The server accepted our `text` for `id` — converged.
    public mutating func noteSendAccepted(_ text: String, for id: String) {
        bases[id] = text
    }

    /// Reconciles a fetched remote version against the local text. Advances
    /// the base for every outcome except `.conflict`, whose resolution is
    /// applied later via `noteConflictResolved`.
    public mutating func resolveRemoteChange(
        id: String,
        localText: String,
        remoteText: String
    ) -> CollabResolution {
        if localText == remoteText {
            bases[id] = remoteText
            return .alreadyConverged
        }

        guard let base = bases[id] else {
            // No base (first sight of this file): a diverging local copy has
            // no ancestry to merge through — treat remote as authoritative
            // only when local is empty, otherwise surface a whole-file
            // conflict for the user.
            if localText.isEmpty {
                bases[id] = remoteText
                return .adoptRemote(remoteText)
            }
            let result = ThreeWayMerge.merge(base: "", mine: localText, theirs: remoteText)
            if result.isClean {
                bases[id] = remoteText
                return .adoptMerged(result.mergedKeepingMine)
            }
            return .conflict(result)
        }

        if base == localText {
            bases[id] = remoteText
            return .adoptRemote(remoteText)
        }
        if base == remoteText {
            // Remote hasn't moved; our local edits are simply ahead.
            return .keepLocal
        }

        let result = ThreeWayMerge.merge(base: base, mine: localText, theirs: remoteText)
        if result.isClean {
            // The merged text incorporates the remote version, so the base
            // advances to remote: future local edits diff against it.
            bases[id] = remoteText
            return .adoptMerged(result.mergedKeepingMine)
        }
        return .conflict(result)
    }

    /// The user resolved a conflict for `id` that was raised against
    /// `remoteText`; the resolution is adopted locally and will be pushed.
    public mutating func noteConflictResolved(remoteText: String, for id: String) {
        bases[id] = remoteText
    }
}

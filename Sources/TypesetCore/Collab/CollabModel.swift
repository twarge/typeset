// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Identity linking a local replica package to its CloudKit document zone.
/// Stored as hidden `.typesetcollab` JSON inside the package (never listed as
/// a package file, like `.typesetstate`); the authoritative identity is the
/// records — this is a cache.
public struct CollabManifest: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case owner
        case participant
    }

    /// CloudKit container identifier, e.g. `iCloud.com.twarge.typeset`.
    public var containerID: String
    /// Zone name; doubles as the stable document identifier.
    public var zoneName: String
    public var role: Role
    /// Cached mapping of package-relative path to stable file record UUID.
    /// File records keep their UUID across renames (the `path` field moves).
    public var fileIDs: [String: String]
    /// True when this document was enrolled automatically for same-user
    /// multi-device sync (not an explicit share). Such documents are gated by
    /// the "Sync my documents via iCloud" preference; explicit shares are not.
    /// Optional for backward compatibility with manifests written before this
    /// field existed (decoded as `nil`, treated as `false`).
    public var autoEnrolled: Bool?

    public var isAutoEnrolled: Bool { autoEnrolled ?? false }

    public init(
        containerID: String,
        zoneName: String,
        role: Role,
        fileIDs: [String: String] = [:],
        autoEnrolled: Bool? = nil
    ) {
        self.containerID = containerID
        self.zoneName = zoneName
        self.role = role
        self.fileIDs = fileIDs
        self.autoEnrolled = autoEnrolled
    }

    public static func decode(_ data: Data) -> CollabManifest? {
        try? JSONDecoder().decode(CollabManifest.self, from: data)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

/// Outcome of reconciling a remote file version against local content.
public enum CollabResolution: Equatable, Sendable {
    /// Local and remote already agree; the base advanced.
    case alreadyConverged
    /// Local never diverged from the base; adopt the remote text.
    case adoptRemote(String)
    /// Remote never diverged from the base; local is ahead — keep local and
    /// push it.
    case keepLocal
    /// Both sides changed without overlap; adopt the merged text and push it.
    case adoptMerged(String)
    /// Both sides changed the same lines; the user must choose per hunk.
    /// The base does not advance until the resolution is applied.
    case conflict(MergeResult)
}

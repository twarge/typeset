// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TypesetCore

// MARK: - Fake server (CloudKit change-tag semantics without CloudKit)

/// Simulates a CloudKit record store: optimistic saves with change tags,
/// `serverRecordChanged`-style rejection on tag mismatch.
private actor FakeServer {
    struct Record: Equatable {
        var text: String
        var tag: Int
    }

    enum SaveResult: Equatable {
        case accepted(tag: Int)
        case serverRecordChanged(serverText: String, serverTag: Int)
    }

    private var records: [String: Record] = [:]

    func fetch(_ id: String) -> Record? {
        records[id]
    }

    func save(_ id: String, text: String, expectedTag: Int?) -> SaveResult {
        let current = records[id]
        guard current?.tag == expectedTag else {
            return .serverRecordChanged(serverText: current?.text ?? "", serverTag: current?.tag ?? 0)
        }
        let newTag = (current?.tag ?? 0) + 1
        records[id] = Record(text: text, tag: newTag)
        return .accepted(tag: newTag)
    }
}

/// A simulated participant: local text, a MergeCoordinator, and the change
/// tag of the last-converged server version.
private struct Client {
    var localText: String
    var coordinator = MergeCoordinator()
    var knownTag: Int?

    /// Pushes local text; on rejection, merges against the server version
    /// and retries once (the CKSyncEngine conflict loop). Returns false when
    /// a hunk conflict requires user resolution.
    mutating func push(_ id: String, to server: FakeServer) async -> Bool {
        switch await server.save(id, text: localText, expectedTag: knownTag) {
        case .accepted(let tag):
            knownTag = tag
            coordinator.noteSendAccepted(localText, for: id)
            return true
        case .serverRecordChanged(let serverText, let serverTag):
            switch coordinator.resolveRemoteChange(id: id, localText: localText, remoteText: serverText) {
            case .alreadyConverged:
                knownTag = serverTag
                return true
            case .adoptRemote(let text):
                localText = text
                knownTag = serverTag
                return true
            case .keepLocal:
                knownTag = serverTag
                return await push(id, to: server)
            case .adoptMerged(let merged):
                localText = merged
                knownTag = serverTag
                return await push(id, to: server)
            case .conflict:
                return false
            }
        }
    }

    /// Applies a fetched server version. Returns false on a hunk conflict.
    mutating func fetchAndApply(_ id: String, from server: FakeServer) async -> Bool {
        guard let record = await server.fetch(id) else { return true }
        switch coordinator.resolveRemoteChange(id: id, localText: localText, remoteText: record.text) {
        case .alreadyConverged:
            knownTag = record.tag
            return true
        case .adoptRemote(let text):
            localText = text
            knownTag = record.tag
            return true
        case .keepLocal:
            knownTag = record.tag
            return true
        case .adoptMerged(let merged):
            localText = merged
            knownTag = record.tag
            return true
        case .conflict:
            return false
        }
    }
}

private func document(_ lines: [String]) -> String {
    lines.joined(separator: "\n") + "\n"
}

// MARK: - Tests

@Test func concurrentDisjointEditsConverge() async {
    let server = FakeServer()
    let id = "file-1"
    let base = document((0..<12).map { "line \($0)" })

    var alice = Client(localText: base)
    var bob = Client(localText: base)
    alice.coordinator.setBase(base, for: id)
    bob.coordinator.setBase(base, for: id)
    #expect(await alice.push(id, to: server))
    bob.knownTag = alice.knownTag

    // Concurrent edits on different lines.
    alice.localText = alice.localText.replacingOccurrences(of: "line 2", with: "line 2 (alice)")
    bob.localText = bob.localText.replacingOccurrences(of: "line 9", with: "line 9 (bob)")

    #expect(await alice.push(id, to: server))
    // Bob's push is rejected (stale tag), merges, retries.
    #expect(await bob.push(id, to: server))
    // Alice fetches Bob's merged result.
    #expect(await alice.fetchAndApply(id, from: server))

    #expect(alice.localText == bob.localText)
    #expect(alice.localText.contains("line 2 (alice)"))
    #expect(alice.localText.contains("line 9 (bob)"))
}

@Test func offlineGapMergesOnReconnect() async {
    let server = FakeServer()
    let id = "file-1"
    let base = document((0..<20).map { "line \($0)" })

    var alice = Client(localText: base)
    var bob = Client(localText: base)
    alice.coordinator.setBase(base, for: id)
    bob.coordinator.setBase(base, for: id)
    #expect(await alice.push(id, to: server))
    bob.knownTag = alice.knownTag

    // Alice pushes two successive changes while Bob is offline editing.
    alice.localText = alice.localText.replacingOccurrences(of: "line 1\n", with: "line 1 (alice a)\n")
    #expect(await alice.push(id, to: server))
    alice.localText = alice.localText.replacingOccurrences(of: "line 3\n", with: "line 3 (alice b)\n")
    #expect(await alice.push(id, to: server))

    bob.localText = bob.localText.replacingOccurrences(of: "line 15\n", with: "line 15 (bob offline)\n")
    bob.localText = bob.localText.replacingOccurrences(of: "line 17\n", with: "line 17 (bob offline)\n")

    // Bob reconnects: stale push -> merge -> retry.
    #expect(await bob.push(id, to: server))
    #expect(await alice.fetchAndApply(id, from: server))

    #expect(alice.localText == bob.localText)
    for marker in ["(alice a)", "(alice b)", "line 15 (bob offline)", "line 17 (bob offline)"] {
        #expect(alice.localText.contains(marker))
    }
}

@Test func overlappingEditsConflictAndResolve() async {
    let server = FakeServer()
    let id = "file-1"
    let base = document((0..<5).map { "line \($0)" })

    var alice = Client(localText: base)
    var bob = Client(localText: base)
    alice.coordinator.setBase(base, for: id)
    bob.coordinator.setBase(base, for: id)
    #expect(await alice.push(id, to: server))
    bob.knownTag = alice.knownTag

    alice.localText = alice.localText.replacingOccurrences(of: "line 2", with: "line 2 (alice)")
    bob.localText = bob.localText.replacingOccurrences(of: "line 2", with: "line 2 (bob)")

    #expect(await alice.push(id, to: server))
    // Bob's push rejects and the merge conflicts.
    #expect(await bob.push(id, to: server) == false)

    // Bob resolves choosing the remote (alice's) side, then pushes.
    let serverRecord = await server.fetch(id)
    let result = ThreeWayMerge.merge(base: base, mine: bob.localText, theirs: serverRecord?.text ?? "")
    #expect(!result.isClean)
    bob.localText = result.resolved(choices: Dictionary(uniqueKeysWithValues: result.conflicts.map { ($0.id, MergeSide.theirs) }))
    bob.coordinator.noteConflictResolved(remoteText: serverRecord?.text ?? "", for: id)
    bob.knownTag = serverRecord?.tag
    #expect(await bob.push(id, to: server))
    #expect(await alice.fetchAndApply(id, from: server))

    #expect(alice.localText == bob.localText)
    #expect(alice.localText.contains("line 2 (alice)"))
    #expect(!alice.localText.contains("line 2 (bob)"))
}

@Test func basesAdvanceOnlyOnConvergence() async {
    let server = FakeServer()
    let id = "file-1"
    let base = document(["alpha", "beta", "gamma"])

    var client = Client(localText: base)
    client.coordinator.setBase(base, for: id)
    #expect(await client.push(id, to: server))
    #expect(client.coordinator.base(for: id) == base)

    // A local edit alone must NOT advance the base.
    client.localText = client.localText.replacingOccurrences(of: "beta", with: "beta edited")
    #expect(client.coordinator.base(for: id) == base)

    // Conflicting remote: base stays put through the conflict.
    let remote = base.replacingOccurrences(of: "beta", with: "beta remote")
    _ = await server.save(id, text: remote, expectedTag: client.knownTag.map { $0 })
    var coordinatorCopy = client.coordinator
    let resolution = coordinatorCopy.resolveRemoteChange(id: id, localText: client.localText, remoteText: remote)
    guard case .conflict = resolution else {
        Issue.record("expected conflict, got \(resolution)")
        return
    }
    #expect(coordinatorCopy.base(for: id) == base)
}

// MARK: - Base store

@Test func fileBaseStoreRoundTrips() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "TypesetBaseStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileCollabBaseStore(rootDirectory: root)

    store.saveBase(CollabBaseEntry(text: "hello\n", changeTag: "tag-1"), documentID: "doc", fileID: "file-a")
    store.saveBase(CollabBaseEntry(text: "world\n", changeTag: nil), documentID: "doc", fileID: "file-b")

    var bases = store.loadBases(documentID: "doc")
    #expect(bases.count == 2)
    #expect(bases["file-a"] == CollabBaseEntry(text: "hello\n", changeTag: "tag-1"))

    store.removeBase(documentID: "doc", fileID: "file-a")
    bases = store.loadBases(documentID: "doc")
    #expect(bases["file-a"] == nil)
    #expect(bases["file-b"] != nil)

    store.removeDocument(documentID: "doc")
    #expect(store.loadBases(documentID: "doc").isEmpty)
}

// MARK: - Manifest

@Test func collabManifestRoundTrips() {
    let manifest = CollabManifest(
        containerID: "iCloud.com.twarge.typeset",
        zoneName: "doc-1234",
        role: .participant,
        fileIDs: ["main.typ": "file-uuid-1"],
        autoEnrolled: true
    )
    let decoded = CollabManifest.decode(manifest.encoded())
    #expect(decoded == manifest)
    #expect(decoded?.isAutoEnrolled == true)
}

@Test func collabManifestDecodesLegacyWithoutAutoEnrolledField() {
    // A manifest written before `autoEnrolled` existed must still decode,
    // defaulting to a non-auto-enrolled (explicit share) document.
    let legacy = #"{"containerID":"iCloud.com.twarge.typeset","zoneName":"doc-9","role":"owner","fileIDs":{}}"#
    let decoded = CollabManifest.decode(Data(legacy.utf8))
    #expect(decoded != nil)
    #expect(decoded?.autoEnrolled == nil)
    #expect(decoded?.isAutoEnrolled == false)
}

@Test func packageRoundTripsCollabManifestWithoutListingIt() throws {
    var package = try DocumentPackage(files: [
        PackageFile(path: "main.typ", data: Data("= Main".utf8)),
    ])
    let manifest = CollabManifest(
        containerID: "iCloud.com.twarge.typeset",
        zoneName: "doc-abc",
        role: .owner
    )
    package.collabManifestData = manifest.encoded()

    let roundTripped = try DocumentPackage(fileWrapper: package.fileWrapper())

    #expect(roundTripped.collabManifestData == manifest.encoded())
    #expect(!roundTripped.files.contains { $0.path == ".typesetcollab" })

    // includeState: false omits editor state but keeps the manifest.
    let stateless = package.fileWrapper(includeState: false)
    #expect(stateless.fileWrappers?[".typesetstate"] == nil)
    #expect(stateless.fileWrappers?[".typesetcollab"] != nil)
}

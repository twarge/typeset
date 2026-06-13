// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CloudKit
import Foundation
import TypesetCore

/// Owns the CloudKit sync engine for one shared document and bridges it to
/// the transport-independent `MergeCoordinator`: local edits become pending
/// record saves; fetched or conflicting server records run through three-way
/// merge resolution and surface to the workspace as `CollabResolution`s.
///
/// Everything CloudKit-specific is runtime-gated: without an iCloud account,
/// entitlement, or manifest, the controller never starts and the app behaves
/// exactly as before.
@MainActor
final class CollabSyncController: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case syncing
        case stopped(String)
    }

    @Published private(set) var status: Status = .idle

    /// Resolution for a remote change to `path`; the workspace applies it to
    /// the document/editor (adopt, merge, or present the conflict sheet).
    var onRemoteResolution: ((String, CollabResolution) -> Void)?
    /// Supplies the current local text for a path (the editor's live text for
    /// the open file, package text otherwise).
    var localTextProvider: ((String) -> String?)?

    private(set) var manifest: CollabManifest
    private var coordinator: MergeCoordinator
    private let baseStore: FileCollabBaseStore
    private var engine: CKSyncEngine?
    private var container: CKContainer?
    /// Last server-known record per file, required to send with the right
    /// change tag. Re-fetched on start; conflicts repair it.
    private var serverRecords: [CKRecord.ID: CKRecord] = [:]
    /// Paths with local edits not yet accepted by the server.
    private var pendingPaths: Set<String> = []

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typeset/Collab/SyncState", directoryHint: .isDirectory)
    }

    private static var baseStoreRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typeset/Collab/Bases", directoryHint: .isDirectory)
    }

    init(manifest: CollabManifest) {
        self.manifest = manifest
        self.baseStore = FileCollabBaseStore(rootDirectory: Self.baseStoreRoot)
        let bases = baseStore.loadBases(documentID: manifest.zoneName)
        self.coordinator = MergeCoordinator(
            bases: bases.mapValues(\.text)
        )
        super.init()
    }

    /// Creates a controller when `package` carries a collaboration manifest.
    static func attached(to package: DocumentPackage) -> CollabSyncController? {
        guard let data = package.collabManifestData,
              let manifest = CollabManifest.decode(data) else { return nil }
        return CollabSyncController(manifest: manifest)
    }

    // MARK: - Lifecycle

    func start() async {
        guard engine == nil else { return }
        status = .starting
        let container = CKContainer(identifier: manifest.containerID)
        do {
            let accountStatus = try await container.accountStatus()
            guard accountStatus == .available else {
                status = .stopped("iCloud account unavailable")
                return
            }
        } catch {
            status = .stopped(error.localizedDescription)
            return
        }
        self.container = container

        let database = manifest.role == .owner
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
        status = .syncing
        try? await engine?.fetchChanges()
    }

    func stop() {
        engine = nil
        status = .idle
    }

    /// Refreshes on demand (app activation, foreground timer) to mitigate
    /// delayed pushes.
    func refresh() async {
        try? await engine?.fetchChanges()
    }

    // MARK: - Local changes

    /// Marks a local edit to `path` for sending. The actual record content is
    /// pulled through `localTextProvider` when the engine asks for the batch.
    func noteLocalEdit(path: String) {
        guard let engine, let fileID = manifest.fileIDs[path] else { return }
        pendingPaths.insert(path)
        let zoneID = CollabSchema.zoneID(forDocumentID: manifest.zoneName)
        engine.state.add(pendingRecordZoneChanges: [
            .saveRecord(CollabSchema.fileRecordID(fileID: fileID, zoneID: zoneID)),
        ])
    }

    // MARK: - State persistence

    private func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        let url = Self.stateURL.appending(path: "\(manifest.zoneName).data")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        let url = Self.stateURL.appending(path: "\(manifest.zoneName).data")
        try? FileManager.default.createDirectory(at: Self.stateURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(serialization) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Merge plumbing

    /// Runs a fetched or conflicting server record through the coordinator
    /// and surfaces the outcome.
    private func resolveServerRecord(_ record: CKRecord) {
        serverRecords[record.recordID] = record
        guard let content = CollabRecordMapping.fileContent(from: record),
              let remoteText = content.text else { return }

        // Keep the manifest's path mapping current (renames move `path`).
        if manifest.fileIDs[content.path] != content.fileID {
            manifest.fileIDs = manifest.fileIDs.filter { $0.value != content.fileID }
            manifest.fileIDs[content.path] = content.fileID
        }

        let localText = localTextProvider?(content.path) ?? remoteText
        let resolution = coordinator.resolveRemoteChange(
            id: content.fileID,
            localText: localText,
            remoteText: remoteText
        )
        if let base = coordinator.base(for: content.fileID) {
            baseStore.saveBase(
                CollabBaseEntry(text: base, changeTag: record.recordChangeTag),
                documentID: manifest.zoneName,
                fileID: content.fileID
            )
        }
        switch resolution {
        case .alreadyConverged:
            pendingPaths.remove(content.path)
        case .keepLocal, .adoptMerged:
            // Local (or merged) content must be pushed back.
            noteLocalEdit(path: content.path)
            onRemoteResolution?(content.path, resolution)
        case .adoptRemote, .conflict:
            onRemoteResolution?(content.path, resolution)
        }
    }

    private func noteSendAccepted(_ record: CKRecord) {
        serverRecords[record.recordID] = record
        guard let content = CollabRecordMapping.fileContent(from: record),
              let text = content.text else { return }
        pendingPaths.remove(content.path)
        coordinator.noteSendAccepted(text, for: content.fileID)
        baseStore.saveBase(
            CollabBaseEntry(text: text, changeTag: record.recordChangeTag),
            documentID: manifest.zoneName,
            fileID: content.fileID
        )
    }
}

// MARK: - CKSyncEngineDelegate

extension CollabSyncController: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            persistStateSerialization(update.stateSerialization)

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                resolveServerRecord(modification.record)
            }

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                noteSendAccepted(saved)
            }
            for failure in sent.failedRecordSaves {
                if let serverRecord = (failure.error as CKError?)?.serverRecord {
                    // The CKSyncEngine conflict path: merge against the
                    // server version and re-queue.
                    resolveServerRecord(serverRecord)
                }
            }

        case .accountChange:
            status = .stopped("iCloud account changed")
            engine = nil

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            await MainActor.run { self.record(for: recordID) }
        }
    }

    /// Builds the outgoing record for `recordID` from current local content,
    /// based on the last server record so the change tag is right.
    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let fileID = CollabSchema.fileID(fromRecordName: recordID.recordName),
              let path = manifest.fileIDs.first(where: { $0.value == fileID })?.key,
              let text = localTextProvider?(path) else { return nil }
        let record = serverRecords[recordID]
            ?? CKRecord(recordType: CollabSchema.fileRecordType, recordID: recordID)
        CollabRecordMapping.applyFileContent(path: path, data: Data(text.utf8), to: record)
        return record
    }
}

// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CloudKit
import Foundation
import TypesetCore

/// Creates and accepts document shares: zone + records + zone-wide CKShare
/// on the owner side; share acceptance + local replica materialization on
/// the participant side.
enum CollabShareManager {
    enum ShareError: LocalizedError {
        case accountUnavailable
        case shareURLMissing

        var errorDescription: String? {
            switch self {
            case .accountUnavailable: "iCloud account is unavailable."
            case .shareURLMissing: "CloudKit did not return a share URL."
            }
        }
    }

    /// Promotes a local package to a shared document: creates the zone, the
    /// document + file records, and a zone-wide share. Returns the manifest
    /// (to store in the package) and the live share.
    @MainActor
    static func createShare(
        for package: DocumentPackage,
        title: String
    ) async throws -> (manifest: CollabManifest, share: CKShare, container: CKContainer) {
        let container = CKContainer(identifier: CollabSchema.containerID)
        guard try await container.accountStatus() == .available else {
            throw ShareError.accountUnavailable
        }
        let database = container.privateCloudDatabase
        let documentID = "doc-\(UUID().uuidString)"
        let zoneID = CollabSchema.zoneID(forDocumentID: documentID)

        var (records, fileIDs) = try await provisionZone(
            documentID: documentID,
            zoneID: zoneID,
            package: package,
            title: title,
            in: database
        )

        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title
        share.publicPermission = .none
        records.append(share)
        _ = try await database.modifyRecords(saving: records, deleting: [])

        let manifest = CollabManifest(
            containerID: CollabSchema.containerID,
            zoneName: documentID,
            role: .owner,
            fileIDs: fileIDs,
            autoEnrolled: false
        )
        return (manifest, share, container)
    }

    /// Enrolls a document for same-user, multi-device live sync through the
    /// owner's private CloudKit database — no `CKShare`. Returns a manifest
    /// stored in the package; iCloud Drive propagates it to the user's other
    /// devices, which then attach to the same zone (their private database is
    /// the same one). Used by the "Sync my documents via iCloud" preference.
    @MainActor
    static func enablePrivateSync(
        for package: DocumentPackage,
        title: String
    ) async throws -> CollabManifest {
        let container = CKContainer(identifier: CollabSchema.containerID)
        guard try await container.accountStatus() == .available else {
            throw ShareError.accountUnavailable
        }
        let database = container.privateCloudDatabase
        let documentID = "doc-\(UUID().uuidString)"
        let zoneID = CollabSchema.zoneID(forDocumentID: documentID)

        let (records, fileIDs) = try await provisionZone(
            documentID: documentID,
            zoneID: zoneID,
            package: package,
            title: title,
            in: database
        )
        _ = try await database.modifyRecords(saving: records, deleting: [])

        return CollabManifest(
            containerID: CollabSchema.containerID,
            zoneName: documentID,
            role: .owner,
            fileIDs: fileIDs,
            autoEnrolled: true
        )
    }

    /// Creates the zone and builds the document + file records (not yet
    /// saved). Shared by the share and private-sync provisioning paths.
    @MainActor
    private static func provisionZone(
        documentID: String,
        zoneID: CKRecordZone.ID,
        package: DocumentPackage,
        title: String,
        in database: CKDatabase
    ) async throws -> (records: [CKRecord], fileIDs: [String: String]) {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

        var fileIDs: [String: String] = [:]
        var records: [CKRecord] = []

        let documentRecord = CKRecord(
            recordType: CollabSchema.documentRecordType,
            recordID: CollabSchema.documentRecordID(zoneID: zoneID)
        )
        CollabRecordMapping.applyDocumentMetadata(
            title: title,
            compileTarget: package.compileTargetPath,
            folders: package.allFolderPaths,
            to: documentRecord
        )
        records.append(documentRecord)

        for file in package.files {
            let fileID = UUID().uuidString
            fileIDs[file.path] = fileID
            let record = CKRecord(
                recordType: CollabSchema.fileRecordType,
                recordID: CollabSchema.fileRecordID(fileID: fileID, zoneID: zoneID)
            )
            CollabRecordMapping.applyFileContent(path: file.path, data: file.data, to: record)
            records.append(record)
        }
        return (records, fileIDs)
    }

    /// Accepts an invitation and materializes a local replica package the
    /// normal document machinery can open; the sync controller fills in file
    /// contents as the first fetch arrives.
    @MainActor
    static func acceptShare(metadata: CKShare.Metadata) async throws -> URL {
        let container = CKContainer(identifier: metadata.containerIdentifier)
        _ = try await container.accept(metadata)

        let documentID = metadata.share.recordID.zoneID.zoneName
        let manifest = CollabManifest(
            containerID: metadata.containerIdentifier,
            zoneName: documentID,
            role: .participant
        )

        // iOS materializes into the app's Documents folder so the replica is
        // discoverable in the document browser (and openable); macOS keeps it
        // in Application Support and opens it via NSWorkspace.
        #if os(iOS)
        let replicaRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "SharedDocuments", directoryHint: .isDirectory)
        #else
        let replicaRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Typeset/SharedDocuments", directoryHint: .isDirectory)
        #endif
        let replicaURL = replicaRoot.appending(path: "\(documentID).typeset", directoryHint: .isDirectory)

        if !FileManager.default.fileExists(atPath: replicaURL.path) {
            var package = try DocumentPackage(files: [
                PackageFile(path: "main.typ", data: Data("// Syncing shared document…\n".utf8)),
            ])
            package.collabManifestData = manifest.encoded()
            let wrapper = package.fileWrapper(includeState: false)
            try FileManager.default.createDirectory(at: replicaRoot, withIntermediateDirectories: true)
            try wrapper.write(to: replicaURL, options: .atomic, originalContentsURL: nil)
        }
        return replicaURL
    }
}

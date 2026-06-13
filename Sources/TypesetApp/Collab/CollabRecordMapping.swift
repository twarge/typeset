// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import CloudKit
import Foundation
import TypesetCore

/// CloudKit schema for a shared document: one zone per document in the
/// owner's private database, shared zone-wide.
enum CollabSchema {
    static let containerID = "iCloud.com.twarge.typeset"

    static let documentRecordType: CKRecord.RecordType = "TSDocument"
    static let fileRecordType: CKRecord.RecordType = "TSFile"

    /// The singleton document record's name inside the zone.
    static let documentRecordName = "document"

    // TSDocument fields.
    static let titleKey = "title"
    static let compileTargetKey = "compileTarget"
    static let foldersKey = "folders"
    static let formatVersionKey = "formatVersion"

    // TSFile fields. Files keep a stable UUID record name across renames —
    // only `path` changes — so concurrent rename + edit never forks a file.
    static let pathKey = "path"
    static let contentInlineKey = "contentInline"
    static let contentAssetKey = "contentAsset"
    static let isTextKey = "isText"

    /// Text above this UTF-8 size ships as a `CKAsset` instead of an inline
    /// string (CloudKit records cap at 1 MB).
    static let inlineContentLimit = 700_000

    static let formatVersion = 1

    static func zoneID(forDocumentID documentID: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: documentID, ownerName: CKCurrentUserDefaultName)
    }

    static func fileRecordID(fileID: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "file-\(fileID)", zoneID: zoneID)
    }

    static func documentRecordID(zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: documentRecordName, zoneID: zoneID)
    }

    static func fileID(fromRecordName recordName: String) -> String? {
        guard recordName.hasPrefix("file-") else { return nil }
        return String(recordName.dropFirst("file-".count))
    }
}

/// A file's content decoded from a `TSFile` record.
struct CollabFileContent: Equatable {
    var fileID: String
    var path: String
    var data: Data

    var text: String? {
        String(data: data, encoding: .utf8)
    }
}

enum CollabRecordMapping {
    /// Populates a `TSFile` record's payload fields from package file content.
    /// Inline UTF-8 for editable text under the size cap, `CKAsset` otherwise.
    static func applyFileContent(path: String, data: Data, to record: CKRecord) {
        record[CollabSchema.pathKey] = path
        if let text = String(data: data, encoding: .utf8), data.count <= CollabSchema.inlineContentLimit {
            record[CollabSchema.contentInlineKey] = text
            record[CollabSchema.contentAssetKey] = nil
            record[CollabSchema.isTextKey] = 1
        } else {
            let assetURL = FileManager.default.temporaryDirectory
                .appending(path: "TypesetCollabAssets", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString)
            try? FileManager.default.createDirectory(
                at: assetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: assetURL)
            record[CollabSchema.contentInlineKey] = nil
            record[CollabSchema.contentAssetKey] = CKAsset(fileURL: assetURL)
            record[CollabSchema.isTextKey] = String(data: data, encoding: .utf8) != nil ? 1 : 0
        }
    }

    /// Decodes a `TSFile` record back into path + content.
    static func fileContent(from record: CKRecord) -> CollabFileContent? {
        guard record.recordType == CollabSchema.fileRecordType,
              let fileID = CollabSchema.fileID(fromRecordName: record.recordID.recordName),
              let path = record[CollabSchema.pathKey] as? String else { return nil }
        if let text = record[CollabSchema.contentInlineKey] as? String {
            return CollabFileContent(fileID: fileID, path: path, data: Data(text.utf8))
        }
        if let asset = record[CollabSchema.contentAssetKey] as? CKAsset,
           let url = asset.fileURL,
           let data = try? Data(contentsOf: url) {
            return CollabFileContent(fileID: fileID, path: path, data: data)
        }
        return nil
    }

    /// Populates the singleton `TSDocument` record from package metadata.
    static func applyDocumentMetadata(
        title: String,
        compileTarget: String,
        folders: [String],
        to record: CKRecord
    ) {
        record[CollabSchema.titleKey] = title
        record[CollabSchema.compileTargetKey] = compileTarget
        record[CollabSchema.foldersKey] = folders
        record[CollabSchema.formatVersionKey] = CollabSchema.formatVersion
    }
}

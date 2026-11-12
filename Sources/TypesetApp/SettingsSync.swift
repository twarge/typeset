// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MetricKit
import OSLog

/// Carries the user's editing preferences between their devices through
/// iCloud's key-value store.
///
/// Settings stay in `UserDefaults`, where every `@AppStorage` reads them; this
/// only copies a fixed list of keys in both directions. What describes one
/// device rather than the person stays put: window layout, font size, split
/// positions, search history, and anything a Focus filter has set.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let syncedKeys: [String] = [
        "newDocument.includesSampleContent",
        "sourceEditor.showLineNumbers",
        "sourceEditor.spellChecking",
        "sourceEditor.spellCheckingIgnoresCommands",
        "sourceEditor.updateReferencesOnRename",
        "sourceEditor.imageInsertTemplate",
        "sourceEditor.figureInsertTemplate",
        "sourceEditor.tableInsertTemplate",
        "editor.holdErrorPopupWhileEditing",
        "preview.renderWarmupDelay",
        "preview.autoRetriggerDelay",
    ]

    private let defaults: UserDefaults
    private let store: NSUbiquitousKeyValueStore
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, store: NSUbiquitousKeyValueStore = .default) {
        self.defaults = defaults
        self.store = store
    }

    /// Begins syncing. Without the iCloud entitlement, or signed out of
    /// iCloud, the store simply never reports or accepts anything.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pull(keys: keys ?? Self.syncedKeys) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.push() }
        })
        store.synchronize()
        pull(keys: Self.syncedKeys)
    }

    /// Cloud to device, for keys the cloud has a value for.
    private func pull(keys: [String]) {
        for key in keys where Self.syncedKeys.contains(key) {
            guard let value = store.object(forKey: key) as? NSObject,
                  (defaults.object(forKey: key) as? NSObject) != value
            else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Device to cloud, for keys the user has actually set. A registered
    /// default is not a choice and must not overwrite one made elsewhere.
    private func push() {
        let chosen = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in Self.syncedKeys {
            guard let value = chosen[key] as? NSObject,
                  (store.object(forKey: key) as? NSObject) != value
            else { continue }
            store.set(value, forKey: key)
        }
    }
}

/// Keeps the crash, hang and disk-write reports the system collects for the
/// app, which is otherwise the only place a failure inside the embedded
/// compiler on someone else's device would ever be recorded.
///
/// Reports arrive at most once a day, on a later launch. Each is written as
/// JSON under `Application Support/Typeset/Diagnostics`, newest twenty kept,
/// and never leaves the device unless the user sends it.
final class DiagnosticReports: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticReports()

    private static let logger = Logger(subsystem: "com.twarge.app.typeset", category: "diagnostics")
    private static let keptReports = 20

    static var directoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "Typeset", directoryHint: .isDirectory)
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            Self.logger.notice("Diagnostic report: \(crashes) crashes, \(hangs) hangs")
            Self.store(payload.jsonRepresentation(), endingAt: payload.timeStampEnd)
        }
    }

    private static func store(_ data: Data, endingAt date: Date) {
        guard let directory = directoryURL else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "report-\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            try data.write(to: directory.appending(path: name), options: .atomic)
            let reports = try fileManager.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("report-") }
                .sorted()
            for stale in reports.dropLast(keptReports) {
                try? fileManager.removeItem(at: directory.appending(path: stale))
            }
        } catch {
            logger.error("Could not store a diagnostic report: \(error.localizedDescription)")
        }
    }
}

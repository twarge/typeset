// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit
import Foundation

/// Persists user-granted folder access across launches with security-scoped
/// bookmarks kept in `UserDefaults`. The App Sandbox only grants access to
/// the document the user opened, so features that reach outside it — loading
/// the folder that encloses a bare `.typ` file, or writing a PDF export next
/// to the document — first route through this store.
@MainActor
enum FolderAccessStore {
    private static let defaultsKey = "folderAccess.bookmarks"

    /// Folders whose security scope has been activated. Scope is retained for
    /// the lifetime of the app so the directory watcher, file writes, and the
    /// spawned Typst process keep the grant; this set only prevents stacking
    /// redundant claims on repeated lookups.
    private static var activeScopePaths: Set<String> = []

    /// Returns true when `folderURL` is usable for the requested operations,
    /// activating a stored bookmark when one covers it. Never prompts.
    static func hasAccess(to folderURL: URL, requiresWrite: Bool = false) -> Bool {
        let folder = folderURL.standardizedFileURL
        if isAccessible(folder, requiresWrite: requiresWrite) { return true }
        return restoreAccess(to: folder, requiresWrite: requiresWrite)
    }

    /// Ensures access to `folderURL`, asking the user to select the folder in
    /// an open panel when no stored grant covers it. Returns false when the
    /// user declines or the selected folder does not provide access.
    static func ensureAccess(
        to folderURL: URL,
        requiresWrite: Bool = false,
        message: String
    ) -> Bool {
        let folder = folderURL.standardizedFileURL
        if hasAccess(to: folder, requiresWrite: requiresWrite) { return true }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Grant Access"
        panel.message = message
        guard panel.runModal() == .OK, let granted = panel.url else { return false }

        saveBookmark(for: granted)
        activateScope(for: granted)
        return isAccessible(folder, requiresWrite: requiresWrite)
    }

    private static func isAccessible(_ folder: URL, requiresWrite: Bool) -> Bool {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: folder.path) else { return false }
        return !requiresWrite || manager.isWritableFile(atPath: folder.path)
    }

    private static func restoreAccess(to folder: URL, requiresWrite: Bool) -> Bool {
        for (path, data) in storedBookmarks() {
            guard folder.path == path || folder.path.hasPrefix(path + "/") else { continue }
            var isStale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                removeBookmark(for: path)
                continue
            }
            activateScope(for: resolved)
            if isStale {
                removeBookmark(for: path)
                saveBookmark(for: resolved)
            }
            if isAccessible(folder, requiresWrite: requiresWrite) { return true }
        }
        return false
    }

    private static func activateScope(for url: URL) {
        let path = url.standardizedFileURL.path
        guard !activeScopePaths.contains(path) else { return }
        if url.startAccessingSecurityScopedResource() {
            activeScopePaths.insert(path)
        }
    }

    private static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var bookmarks = storedBookmarks()
        bookmarks[url.standardizedFileURL.path] = data
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    private static func removeBookmark(for path: String) {
        var bookmarks = storedBookmarks()
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    private static func storedBookmarks() -> [String: Data] {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        return stored.compactMapValues { $0 as? Data }
    }
}
#endif

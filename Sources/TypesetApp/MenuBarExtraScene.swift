// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
import AppKit

/// An optional menu bar item for starting or reopening a document without
/// bringing a Typeset window forward first. Off unless turned on in Settings:
/// an editor has no business in the menu bar uninvited.
///
/// An AppKit status item rather than SwiftUI's `MenuBarExtra`: that scene,
/// declared beside a `DocumentGroup`, crashes SwiftUI's document controller
/// setup at launch.
@MainActor
final class MenuBarItemController: NSObject, NSMenuDelegate {
    static let shared = MenuBarItemController()
    static let isShownKey = "app.showsMenuBarExtra"

    private var statusItem: NSStatusItem?
    private var observer: NSObjectProtocol?

    /// Shows or hides the item to match the setting, now and whenever it
    /// changes.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let isShown = UserDefaults.standard.bool(forKey: Self.isShownKey)
        if isShown, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Typeset")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if !isShown, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Rebuilt each time it opens, so the recent documents are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item(String(localized: "New Document"), #selector(newDocument)))
        menu.addItem(item(String(localized: "Open…"), #selector(openDocument)))

        let recents = NSDocumentController.shared.recentDocumentURLs.prefix(10)
        if !recents.isEmpty {
            menu.addItem(.separator())
            for url in recents {
                let entry = item(url.deletingPathExtension().lastPathComponent, #selector(openRecent(_:)))
                entry.representedObject = url
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Typeset"), #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func newDocument() {
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.newDocument(nil)
    }

    @objc private func openDocument() {
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.openDocument(nil)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
#endif

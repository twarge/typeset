// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import PhotosUI
import PDFKit
import SwiftUI
import TypesetCore
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
import QuickLookUI
#else
import UIKit
import QuickLook
#endif

#if os(macOS)
struct AppAppearanceConfigurator: NSViewRepresentable {
    var themePreference: ThemePreference

    func makeNSView(context: Context) -> NSView {
        AppearanceView(themePreference: themePreference)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let appearanceView = nsView as? AppearanceView else { return }
        appearanceView.themePreference = themePreference
    }

    final class AppearanceView: NSView {
        var themePreference: ThemePreference {
            didSet {
                guard oldValue != themePreference else { return }
                applyAppearance()
            }
        }

        init(themePreference: ThemePreference) {
            self.themePreference = themePreference
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            let appearance = themePreference.nsAppearance
            DispatchQueue.main.async {
                NSApp.appearance = appearance
                NSApp.windows.forEach { window in
                    window.appearance = appearance
                }
            }
        }
    }
}

struct DocumentProxyConfigurator: NSViewRepresentable {
    var fileURL: URL?
    var editedPath: String

    func makeNSView(context: Context) -> NSView {
        ProxyView(fileURL: fileURL, editedPath: editedPath)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let proxyView = nsView as? ProxyView else { return }
        proxyView.fileURL = fileURL
        proxyView.editedPath = editedPath
    }

    final class ProxyView: NSView {
        var fileURL: URL? {
            didSet {
                configureWindow()
            }
        }

        var editedPath: String {
            didSet {
                configureWindow()
            }
        }

        init(fileURL: URL?, editedPath: String) {
            self.fileURL = fileURL
            self.editedPath = editedPath
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        private func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            if UserDefaults.standard.object(forKey: "NSWindow Frame Typeset.MainWindow") == nil {
                window.setContentSize(NSSize(width: 1280, height: 860))
                window.center()
            }
            window.setFrameAutosaveName("Typeset.MainWindow")
            window.representedURL = fileURL
            window.title = windowTitle
        }

        private var windowTitle: String {
            guard let fileURL else { return "Typeset" }
            let documentTitle: String
            if fileURL.pathExtension.lowercased() == "typeset" {
                documentTitle = fileURL.deletingPathExtension().lastPathComponent
            } else {
                documentTitle = fileURL.lastPathComponent
            }
            guard !editedPath.isEmpty else { return documentTitle }
            // A chevron breadcrumb (matching the iOS title's grey `chevron.right`)
            // rather than a dash. `NSWindow.title` is plain text drawn in the
            // muted titlebar color, so the separator reads grey.
            return "\(documentTitle) › \(editedPath)"
        }
    }
}

struct SplitViewStateConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SplitStateView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let splitStateView = nsView as? SplitStateView else { return }
        splitStateView.configureSplitView()
    }

    final class SplitStateView: NSView {
        private var didSetInitialSidebarWidth = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureSplitView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureSplitView()
        }

        func configureSplitView() {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let splitView = self.firstAncestor(ofType: NSSplitView.self) ?? self.window?.contentView?.firstDescendant(ofType: NSSplitView.self) else {
                    return
                }

                splitView.autosaveName = NSSplitView.AutosaveName("Typeset.WorkspaceSidebar")
                guard !self.didSetInitialSidebarWidth,
                      UserDefaults.standard.object(forKey: "NSSplitView Subview Frames Typeset.WorkspaceSidebar") == nil,
                      splitView.arrangedSubviews.count > 1 else {
                    return
                }

                splitView.setPosition(320, ofDividerAt: 0)
                self.didSetInitialSidebarWidth = true
            }
        }
    }
}

private extension NSView {
    func firstAncestor<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        var current = superview
        while let view = current {
            if let match = view as? ViewType {
                return match
            }
            current = view.superview
        }
        return nil
    }

    func firstDescendant<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }

        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }

        return nil
    }
}

private extension ThemePreference {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
#endif

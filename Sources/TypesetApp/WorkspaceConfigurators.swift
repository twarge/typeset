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

    func makeNSView(context: Context) -> NSView {
        ProxyView(fileURL: fileURL)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let proxyView = nsView as? ProxyView else { return }
        proxyView.fileURL = fileURL
    }

    final class ProxyView: NSView {
        var fileURL: URL? {
            didSet {
                configureWindow()
            }
        }

        init(fileURL: URL?) {
            self.fileURL = fileURL
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
            // Standard document chrome: the represented URL gives the proxy icon
            // and drives the system "— Edited" indicator. Whether the title shows
            // is handled in the view layer via `.toolbar(removing: .title)`, toggled
            // with the distraction-free reveal state.
            window.representedURL = fileURL
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

struct DistractionFreeWindowChromeConfigurator: NSViewRepresentable {
    var isEnabled: Bool
    // Fires whenever the auto-hide state flips, so SwiftUI can fade the toolbar
    // contents to match. The toolbar itself is deliberately never hidden — doing
    // so lets the system document title fall back into the title bar — so the
    // chrome is faded to transparent in place instead.
    var onChromeHiddenChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        ChromeView(isEnabled: isEnabled, onChromeHiddenChange: onChromeHiddenChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let chromeView = nsView as? ChromeView else { return }
        chromeView.onChromeHiddenChange = onChromeHiddenChange
        chromeView.isEnabled = isEnabled
    }

    final class ChromeView: NSView {
        var isEnabled: Bool {
            didSet {
                guard oldValue != isEnabled else { return }
                applyMode()
            }
        }

        var onChromeHiddenChange: (Bool) -> Void

        private weak var configuredWindow: NSWindow?
        private weak var trackingView: NSView?
        private var trackingArea: NSTrackingArea?
        private var isChromeHidden = false
        private let revealHeight: CGFloat = 92
        // Once shown, the toolbar stays until the pointer drops this much further,
        // so it doesn't strobe at the lower edge of the reveal strip.
        private let revealHysteresis: CGFloat = 48
        // The hide is debounced: the pointer must stay out of the reveal strip
        // this long before the chrome hides. Revealing the toolbar can momentarily
        // shift the strip and crossing toolbar items fires excursions; the delay
        // lets those resolve instead of strobing.
        private var hideTask: Task<Void, Never>?

        init(isEnabled: Bool, onChromeHiddenChange: @escaping (Bool) -> Void) {
            self.isEnabled = isEnabled
            self.onChromeHiddenChange = onChromeHiddenChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        isolated deinit {
            removeTrackingArea()
            restoreWindowChrome()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyMode()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyMode()
        }

        private func applyMode() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncConfiguredWindow()

                guard self.isEnabled else {
                    self.removeTrackingArea()
                    self.restoreWindowChrome()
                    return
                }

                self.installTrackingAreaIfNeeded()
                self.updateChromeVisibilityForCurrentPointer()
            }
        }

        private func syncConfiguredWindow() {
            guard configuredWindow !== window else { return }
            removeTrackingArea()
            restoreWindowChrome()
            configuredWindow = window
            isChromeHidden = false
        }

        private func installTrackingAreaIfNeeded() {
            guard let contentView = configuredWindow?.contentView else { return }
            guard trackingArea == nil || trackingView !== contentView else { return }
            removeTrackingArea()

            let options: NSTrackingArea.Options = [
                .activeInKeyWindow,
                .enabledDuringMouseDrag,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved,
            ]
            let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
            contentView.addTrackingArea(area)
            trackingArea = area
            trackingView = contentView
        }

        private func removeTrackingArea() {
            if let trackingArea, let trackingView {
                trackingView.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            trackingView = nil
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            updateChromeVisibilityFor(event)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            updateChromeVisibilityFor(event)
        }

        override func mouseDragged(with event: NSEvent) {
            super.mouseDragged(with: event)
            updateChromeVisibilityFor(event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            super.rightMouseDragged(with: event)
            updateChromeVisibilityFor(event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            super.otherMouseDragged(with: event)
            updateChromeVisibilityFor(event)
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            updateChromeVisibilityFor(event)
        }

        private func updateChromeVisibilityFor(_ event: NSEvent) {
            guard isEnabled, let window = configuredWindow else { return }
            if isPointerInRevealArea(of: window, event: event) {
                cancelPendingHide()
                setWindowChromeHidden(false)
            } else {
                scheduleHide()
            }
        }

        private func updateChromeVisibilityForCurrentPointer() {
            guard isEnabled, let window = configuredWindow else { return }
            if isPointerInRevealArea(of: window) {
                cancelPendingHide()
                setWindowChromeHidden(false)
            } else {
                scheduleHide()
            }
        }

        private func scheduleHide() {
            // Only schedule once; a hide already in flight stands until it fires or
            // is cancelled by the pointer returning to the strip.
            guard !isChromeHidden, hideTask == nil else { return }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled else { return }
                self.hideTask = nil
                // Re-check: only hide if the pointer is still out of the strip.
                guard self.isEnabled, let window = self.configuredWindow,
                      !self.isPointerInRevealArea(of: window) else { return }
                self.setWindowChromeHidden(true)
            }
        }

        private func cancelPendingHide() {
            hideTask?.cancel()
            hideTask = nil
        }

        private func isPointerInRevealArea(of window: NSWindow) -> Bool {
            let point = NSEvent.mouseLocation
            return isScreenPointInRevealArea(point, of: window)
        }

        private func isPointerInRevealArea(of window: NSWindow, event: NSEvent) -> Bool {
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            return isScreenPointInRevealArea(point, of: window)
        }

        private func isScreenPointInRevealArea(_ point: NSPoint, of window: NSWindow) -> Bool {
            let frame = window.frame
            guard point.x >= frame.minX, point.x <= frame.maxX else { return false }
            // `NSRect.contains` excludes the max-Y edge — which is exactly the
            // toolbar strip — so the pointer resting on the toolbar would read as
            // outside the window and strobe. Test the top strip inclusively, and
            // hold the toolbar a little further down once shown (hysteresis).
            let distanceFromTop = frame.maxY - point.y
            guard distanceFromTop >= 0 else { return false }
            let limit = isChromeHidden ? revealHeight : revealHeight + revealHysteresis
            return distanceFromTop <= limit
        }

        private func setWindowChromeHidden(_ hidden: Bool) {
            guard isChromeHidden != hidden else { return }
            isChromeHidden = hidden
            // Publish to SwiftUI, which conditionally removes the toolbar's own
            // items. The traffic lights are deliberately left untouched: hiding them
            // — even with alpha, not just `isHidden` — makes ⌘W/⌘M silently no-op,
            // because `performClose:`/`performMiniaturize:` work by simulating a
            // click on those buttons. Leaving them visible keeps the commands working.
            onChromeHiddenChange(hidden)
        }

        private func restoreWindowChrome() {
            cancelPendingHide()
            isChromeHidden = false
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

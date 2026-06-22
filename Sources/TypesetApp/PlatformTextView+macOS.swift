// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TypesetCore
import UniformTypeIdentifiers
import OSLog
import CoreText

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
struct PlatformTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    var isEditable: Bool
    var focusRequest: Int
    var commentToggleRequest: Int
    var snippetInsertion: EditorSnippetInsertion?
    var insertableImagePaths: Set<String>
    var insertableTypstPaths: Set<String>
    var imageInsertTemplate: String
    var onImportExternalFile: @MainActor (URL) -> String?
    var onImportPastedImage: @MainActor (Data, String) -> String?
    var diagnostics: [TypstSourceDiagnostic]
    var proseRanges: [TypstProseRange]
    var showLineNumbers: Bool
    var spellCheckingEnabled: Bool
    var onTextChange: (String, NSRange) -> Void
    var onSelectionChange: (NSRange) -> Void
    var isCompletionPresented: Bool
    var onCompletionMove: (Int) -> Void
    var onCompletionAccept: () -> Void
    var onCompletionDismiss: () -> Void
    var onScrollOffsetChange: (CGFloat) -> Void
    var onLanguageOverlayAnchorChange: (CGPoint) -> Void
    var onScrollFractionChange: (Double) -> Void = { _ in }
    var scrollRestore: SourceEditorScrollRestore?
    @Binding var isPackageDropTargeted: Bool
    @Binding var fontSize: Double

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PackagePathTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = context.coordinator.font()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        // Don't paint the text-background color — let whatever the window/detail
        // column is showing come through, so the editor blends with the rim
        // around the floating sidebar instead of reading as a distinct surface.
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.registerForDraggedTypes([
            NSPasteboard.PasteboardType(UTType.typesetPackageFileDrag.identifier),
            NSPasteboard.PasteboardType(UTType.fileURL.identifier),
            NSPasteboard.PasteboardType(UTType.plainText.identifier),
            .fileURL,
            .string,
        ])
        context.coordinator.textView = textView
        textView.onCompletionKey = { [weak coordinator = context.coordinator] event in
            coordinator?.handleCompletionKey(event) == true
        }
        textView.onUserInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.clearScrollAnchor()
        }
        context.coordinator.configureDropHandling(for: textView)
        context.coordinator.applyHighlighting(to: textView, text: text)

        // Plain NSScrollView with default `automaticallyAdjustsContentInsets`.
        // Combined with the SwiftUI `.ignoresSafeArea(.container, edges: .top)`
        // on the source pane, AppKit positions content below the toolbar at
        // rest AND installs the macOS 26 top-edge scroll-edge effect (the
        // pocket + variable blur) so content scrolling under the toolbar
        // fades into it instead of meeting a hard edge.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrollView(scrollView)
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers
        scrollView.verticalRulerView = LineNumberRulerView(textView: textView)
        let magnificationGesture = NSMagnificationGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMagnification(_:))
        )
        scrollView.addGestureRecognizer(magnificationGesture)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.insertableImagePaths = insertableImagePaths
        context.coordinator.insertableTypstPaths = insertableTypstPaths
        context.coordinator.imageInsertTemplate = imageInsertTemplate
        context.coordinator.onImportExternalFile = onImportExternalFile
        context.coordinator.onImportPastedImage = onImportPastedImage
        context.coordinator.diagnostics = diagnostics
        context.coordinator.proseRanges = proseRanges
        context.coordinator.spellCheckingEnabled = spellCheckingEnabled
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.isCompletionPresented = isCompletionPresented
        context.coordinator.onCompletionMove = onCompletionMove
        context.coordinator.onCompletionAccept = onCompletionAccept
        context.coordinator.onCompletionDismiss = onCompletionDismiss
        context.coordinator.onLanguageOverlayAnchorChange = onLanguageOverlayAnchorChange
        context.coordinator.isPackageDropTargeted = $isPackageDropTargeted
        context.coordinator.updateFontSize(fontSize, in: textView)
        textView.textContainerInset = NSSize(width: 18, height: 18)
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers
        (scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineNumbers()

        if textView.string != text {
            if context.coordinator.shouldKeepNativeText(textView.string, representedText: text) {
                context.coordinator.repaintSyntaxOnly(in: textView)
            } else {
                context.coordinator.applyHighlighting(to: textView, text: text)
            }
        } else {
            context.coordinator.markRepresentedTextSynced(text)
            context.coordinator.repaintSyntaxOnly(in: textView)
        }
        textView.isEditable = isEditable

        if let selectedRange, textView.selectedRange() != selectedRange {
            textView.setSelectedRange(selectedRange)
            // Navigation (preview seek, outline, diagnostics) anchors the
            // target range so late layout can't drift it off-screen.
            context.coordinator.anchorScroll(to: selectedRange)
            DispatchQueue.main.async {
                self.selectedRange = nil
            }
        }
        context.coordinator.toggleCommentIfNeeded(commentToggleRequest, in: textView)
        context.coordinator.insertSnippetIfNeeded(snippetInsertion, in: textView)
        context.coordinator.focusIfNeeded(focusRequest, textView: textView)
        context.coordinator.onScrollFractionChange = onScrollFractionChange
        context.coordinator.restoreScrollIfNeeded(scrollRestore)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            fontSize: $fontSize,
            insertableImagePaths: insertableImagePaths,
            insertableTypstPaths: insertableTypstPaths,
            imageInsertTemplate: imageInsertTemplate,
            onImportExternalFile: onImportExternalFile,
            onImportPastedImage: onImportPastedImage,
            diagnostics: diagnostics,
            proseRanges: proseRanges,
            spellCheckingEnabled: spellCheckingEnabled,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange,
            isCompletionPresented: isCompletionPresented,
            onCompletionMove: onCompletionMove,
            onCompletionAccept: onCompletionAccept,
            onCompletionDismiss: onCompletionDismiss,
            onLanguageOverlayAnchorChange: onLanguageOverlayAnchorChange,
            isPackageDropTargeted: $isPackageDropTargeted
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var fontSize: Double
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var onScrollFractionChange: ((Double) -> Void)?
        private var lastScrollRestoreToken = 0
        private var isRestoringScroll = false

        /// The scroll anchor: while set, the editor keeps this range visible
        /// (centered), recomputing its position from current layout whenever
        /// anything disturbs the view — late layout growth, pane resizes, and
        /// AppKit's own re-centering (animated or not) all self-correct
        /// toward the anchor instead of being fought pixel-by-pixel. Cleared
        /// the moment the user takes over (wheel, click, typing).
        private var scrollAnchorRange: NSRange?
        private var scrollAnchorFraction: Double?
        private var isEnforcingScrollAnchor = false

        /// Glues the view to `range` until the user interacts.
        func anchorScroll(to range: NSRange) {
            scrollAnchorRange = range
            scrollAnchorFraction = nil
            isRestoringScroll = true
            enforceScrollAnchor()
        }

        /// Glues the view to a saved vertical fraction until the user interacts.
        func anchorScroll(toFraction fraction: Double) {
            scrollAnchorRange = nil
            scrollAnchorFraction = min(1, max(0, fraction.isFinite ? fraction : 0))
            isRestoringScroll = true
            enforceScrollAnchor()
        }

        /// Hands scroll control to the user: the anchor stops tracking.
        func clearScrollAnchor() {
            scrollAnchorRange = nil
            scrollAnchorFraction = nil
            isRestoringScroll = false
        }

        @objc private func scrollViewWillStartLiveScroll(_ notification: Notification) {
            // Programmatic animated scrolls (AppKit's deferred text-view
            // re-centering among them) also post live-scroll notifications.
            // Only treat this as the user when there is *fresh* input
            // evidence: a held mouse button (scroller drag) or a wheel or
            // gesture event younger than half a second — `NSApp.currentEvent`
            // is merely the last processed event and can be arbitrarily old.
            let event = NSApp.currentEvent
            let eventAge = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp } ?? .infinity
            let eventType = event?.type
            let isFreshScrollEvent = eventAge < 0.5
                && (eventType == .scrollWheel || eventType == .magnify || eventType == .beginGesture)
            let isUserDriven = NSEvent.pressedMouseButtons != 0 || isFreshScrollEvent
            guard isUserDriven else { return }
            clearScrollAnchor()
        }

        /// Scrolls so the anchor range is centered (or at the top for an
        /// anchor at the document start), based on the *current* layout.
        private func enforceScrollAnchor() {
            guard !isEnforcingScrollAnchor, let scrollView else { return }

            if let anchor = scrollAnchorRange {
                guard let textView,
                      let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer else { return }
                layoutManager.ensureLayout(for: textContainer)
                let length = (textView.string as NSString).length
                let location = min(max(0, anchor.location), length)
                let len = min(anchor.length, max(0, length - location))
                let range = NSRange(location: location, length: len)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.y += textView.textContainerOrigin.y
                let documentFrame = scrollView.documentView?.frame ?? .zero
                let viewport = scrollView.contentView.bounds.height
                let maxScroll = max(0, documentFrame.height - viewport)
                let visibleY = min(maxScroll, max(0, rect.midY - viewport / 2))
                let target = documentFrame.minY + visibleY
                let current = scrollView.contentView.bounds.origin.y
                guard abs(current - target) > 2 else { return }
                isEnforcingScrollAnchor = true
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                isEnforcingScrollAnchor = false
                return
            }

            guard let fraction = scrollAnchorFraction,
                  let documentView = scrollView.documentView else { return }
            let documentFrame = documentView.frame
            let viewport = scrollView.contentView.bounds.height
            let maxScroll = max(0, documentFrame.height - viewport)
            let target = documentFrame.minY + maxScroll * CGFloat(min(1, max(0, fraction)))
            let current = scrollView.contentView.bounds.origin.y
            guard abs(current - target) > 2 else { return }
            isEnforcingScrollAnchor = true
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isEnforcingScrollAnchor = false
        }
        var insertableImagePaths: Set<String>
        var insertableTypstPaths: Set<String>
        var imageInsertTemplate: String
        var onImportExternalFile: @MainActor (URL) -> String?
        var onImportPastedImage: @MainActor (Data, String) -> String?
        var diagnostics: [TypstSourceDiagnostic]
        var proseRanges: [TypstProseRange]
        var spellCheckingEnabled: Bool
        var onTextChange: (String, NSRange) -> Void
        var onSelectionChange: (NSRange) -> Void
        var isCompletionPresented: Bool
        var onCompletionMove: (Int) -> Void
        var onCompletionAccept: () -> Void
        var onCompletionDismiss: () -> Void
        var onLanguageOverlayAnchorChange: (CGPoint) -> Void
        var isPackageDropTargeted: Binding<Bool>
        private var isApplyingHighlighting = false
        private var gestureStartFontSize = SourceEditorFont.defaultSize
        private var gestureCurrentFontSize = SourceEditorFont.defaultSize
        private var appliedFontSize = 0.0
        private var lastFocusRequest = 0
        private var lastCommentToggleRequest = 0
        private var lastSnippetToken = 0
        private var nativeTextAwaitingBinding: String?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        init(
            text: Binding<String>,
            fontSize: Binding<Double>,
            insertableImagePaths: Set<String>,
            insertableTypstPaths: Set<String>,
            imageInsertTemplate: String,
            onImportExternalFile: @escaping @MainActor (URL) -> String?,
            onImportPastedImage: @escaping @MainActor (Data, String) -> String?,
            diagnostics: [TypstSourceDiagnostic],
            proseRanges: [TypstProseRange],
            spellCheckingEnabled: Bool,
            onTextChange: @escaping (String, NSRange) -> Void,
            onSelectionChange: @escaping (NSRange) -> Void,
            isCompletionPresented: Bool,
            onCompletionMove: @escaping (Int) -> Void,
            onCompletionAccept: @escaping () -> Void,
            onCompletionDismiss: @escaping () -> Void,
            onLanguageOverlayAnchorChange: @escaping (CGPoint) -> Void,
            isPackageDropTargeted: Binding<Bool>
        ) {
            _text = text
            _fontSize = fontSize
            self.insertableImagePaths = insertableImagePaths
            self.insertableTypstPaths = insertableTypstPaths
            self.imageInsertTemplate = imageInsertTemplate
            self.onImportExternalFile = onImportExternalFile
            self.onImportPastedImage = onImportPastedImage
            self.diagnostics = diagnostics
            self.proseRanges = proseRanges
            self.spellCheckingEnabled = spellCheckingEnabled
            self.onTextChange = onTextChange
            self.onSelectionChange = onSelectionChange
            self.isCompletionPresented = isCompletionPresented
            self.onCompletionMove = onCompletionMove
            self.onCompletionAccept = onCompletionAccept
            self.onCompletionDismiss = onCompletionDismiss
            self.onLanguageOverlayAnchorChange = onLanguageOverlayAnchorChange
            self.isPackageDropTargeted = isPackageDropTargeted
        }

        func configureDropHandling(for textView: PackagePathTextView) {
            textView.onValidatePackagePathDrop = { [weak self] path in
                self?.snippet(for: path) != nil
            }
            textView.onPackagePathDropTargeted = { [weak self] isTargeted in
                self?.isPackageDropTargeted.wrappedValue = isTargeted
            }
            textView.onDropPackagePath = { [weak self, weak textView] path, point in
                guard let self, let textView else { return false }
                return self.insertPackageReference(path: path, at: point, in: textView)
            }
            textView.onDropExternalFile = { [weak self, weak textView] url, point in
                guard let self, let textView else { return false }
                return self.importAndInsertExternalFile(url, at: point, in: textView)
            }
            textView.onPasteExternalFile = { [weak self] url in
                self?.snippetForExternalFile(url)
            }
        }

        func observeScrollView(_ scrollView: NSScrollView) {
            self.scrollView = scrollView
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewWillStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
            )
            // Track document-view frame changes too: layout growth moves the
            // anchor's position without necessarily changing clip bounds.
            scrollView.documentView?.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(documentViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView.documentView,
            )
        }

        @objc private func documentViewFrameDidChange(_ notification: Notification) {
            enforceScrollAnchor()
        }

        /// Vertical scroll position as a fraction (0...1) of the scrollable
        /// range, or `nil` when the document fits without scrolling.
        private func currentScrollFraction() -> Double? {
            guard let scrollView, let documentView = scrollView.documentView else { return nil }
            let viewport = scrollView.contentView.bounds.height
            let documentFrame = documentView.frame
            let maxScroll = max(0, documentFrame.height - viewport)
            guard maxScroll > 0 else { return 0 }
            let visibleY = scrollView.contentView.bounds.origin.y - documentFrame.minY
            return Double(min(1, max(0, visibleY / maxScroll)))
        }

        func restoreScrollIfNeeded(_ request: SourceEditorScrollRestore?) {
            guard let request, request.token != lastScrollRestoreToken else { return }
            lastScrollRestoreToken = request.token
            let requestedSelection = request.selection
            let fraction = min(1, max(0, request.fraction.isFinite ? request.fraction : 0))
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                guard self.lastScrollRestoreToken == request.token else { return }
                let length = (textView.string as NSString).length
                let selection: NSRange? = requestedSelection.map { range in
                    let location = min(max(0, range.location), length)
                    let len = min(range.length, max(0, length - location))
                    return NSRange(location: location, length: len)
                }
                if request.revealSelection {
                    if let selection {
                        textView.setSelectedRange(selection)
                    }
                    self.anchorScroll(to: selection ?? NSRange(location: 0, length: 0))
                } else {
                    // Turn on the fraction anchor before applying the saved
                    // caret. AppKit may scroll to reveal the caret while the
                    // text view is still resizing; with the anchor active,
                    // those layout-driven jumps are immediately corrected.
                    self.anchorScroll(toFraction: fraction)
                    if let selection {
                        textView.setSelectedRange(selection)
                    }
                }
                self.updateLanguageOverlayAnchor(in: textView, selectedRange: textView.selectedRange())
                textView.window?.makeFirstResponder(textView)
                if !request.revealSelection {
                    self.enforceScrollAnchor()
                }
            }
        }

        func focusIfNeeded(_ focusRequest: Int, textView: NSTextView) {
            guard focusRequest != lastFocusRequest else { return }
            lastFocusRequest = focusRequest
            focus(textView, remainingAttempts: 4)
        }

        func toggleCommentIfNeeded(_ commentToggleRequest: Int, in textView: NSTextView) {
            guard commentToggleRequest != lastCommentToggleRequest else { return }
            lastCommentToggleRequest = commentToggleRequest
            guard textView.isEditable else { return }
            guard let edit = SourceEditorCommentToggle.edit(
                for: textView.string,
                selectedRange: textView.selectedRange()
            ) else { return }

            textView.insertText(edit.replacementText, replacementRange: edit.replacementRange)
            textView.setSelectedRange(edit.selectedRange)
            textView.scrollRangeToVisible(edit.selectedRange)
            updateLanguageOverlayAnchor(in: textView, selectedRange: edit.selectedRange)
        }

        func insertSnippetIfNeeded(_ request: EditorSnippetInsertion?, in textView: NSTextView) {
            guard let request, request.token != lastSnippetToken else { return }
            lastSnippetToken = request.token
            guard textView.isEditable else { return }
            let selectedRange = textView.selectedRange()
            let selectedText = (textView.string as NSString).substring(with: selectedRange)
            let resolved = SourceEditorDropSnippet.resolveInsertion(
                request.template,
                fallback: request.fallback,
                selectedText: selectedText
            )
            // insertText(_:replacementRange:) registers the edit with the text
            // view's undo manager and fires textDidChange to sync the binding.
            textView.insertText(resolved.text, replacementRange: selectedRange)
            let newSelection = NSRange(
                location: selectedRange.location + resolved.selectionLocation,
                length: resolved.selectionLength
            )
            textView.setSelectedRange(newSelection)
            textView.scrollRangeToVisible(newSelection)
            updateLanguageOverlayAnchor(in: textView, selectedRange: newSelection)
        }

        private func focus(_ textView: NSTextView, remainingAttempts: Int) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard let window = textView.window else {
                    if remainingAttempts > 0 {
                        self.focus(textView, remainingAttempts: remainingAttempts - 1)
                    }
                    return
                }
                window.makeFirstResponder(textView)
            }
        }

        @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
            guard let textView else { return }
            enforceScrollAnchor()
            updateLanguageOverlayAnchor(in: textView, selectedRange: textView.selectedRange())
            if !isRestoringScroll, let fraction = currentScrollFraction() {
                onScrollFractionChange?(fraction)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingHighlighting else { return }
            guard let textView = notification.object as? NSTextView else { return }
            // Edits autoscroll to the caret (typing, paste via menu); the
            // user has taken over.
            clearScrollAnchor()
            let nextText = textView.string
            repaintSyntaxOnly(in: textView)
            let range = textView.selectedRange()
            sendTextChange(nextText, selectedRange: range)
            updateLanguageOverlayAnchor(in: textView, selectedRange: range)
        }

        func handleCompletionKey(_ event: NSEvent) -> Bool {
            guard isCompletionPresented else { return false }
            switch event.keyCode {
            case 125:
                onCompletionMove(1)
                return true
            case 126:
                onCompletionMove(-1)
                return true
            case 36, 48:
                onCompletionAccept()
                return true
            case 53:
                onCompletionDismiss()
                return true
            default:
                return false
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingHighlighting else { return }
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            sendSelectionChange(range)
            updateLanguageOverlayAnchor(in: textView, selectedRange: range)
        }

        private func sendTextChange(_ nextText: String, selectedRange range: NSRange) {
            nativeTextAwaitingBinding = nextText
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.text = nextText
                self.onTextChange(nextText, range)
            }
        }

        func shouldKeepNativeText(_ nativeText: String, representedText: String) -> Bool {
            nativeTextAwaitingBinding == nativeText && representedText != nativeText
        }

        func markRepresentedTextSynced(_ representedText: String) {
            if nativeTextAwaitingBinding == representedText {
                nativeTextAwaitingBinding = nil
            }
        }

        private func sendSelectionChange(_ range: NSRange) {
            DispatchQueue.main.async { [weak self] in
                self?.onSelectionChange(range)
            }
        }

        private func updateLanguageOverlayAnchor(in textView: NSTextView, selectedRange: NSRange) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let textLength = (textView.string as NSString).length
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(selectedRange.location, max(0, textLength)))
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 0), in: textContainer)
            let origin = textView.textContainerOrigin
            let visibleRect = textView.visibleRect
            onLanguageOverlayAnchorChange(CGPoint(
                x: rect.minX + origin.x - visibleRect.minX,
                y: rect.maxY + origin.y - visibleRect.minY
            ))
        }

        func updateFontSize(_ newSize: Double, in textView: NSTextView) {
            let clampedSize = SourceEditorFont.clamped(newSize)
            if abs(clampedSize - fontSize) > 0.01 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, abs(self.fontSize - clampedSize) > 0.01 else { return }
                    self.fontSize = clampedSize
                }
            }
            guard abs(appliedFontSize - clampedSize) > 0.01 else { return }
            applyHighlighting(to: textView, text: textView.string)
        }

        @objc func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
            guard let textView else { return }

            switch gesture.state {
            case .began:
                gestureStartFontSize = fontSize
                gestureCurrentFontSize = fontSize
            case .changed:
                let nextSize = SourceEditorFont.clamped(gestureStartFontSize * (1 + gesture.magnification))
                guard abs(nextSize - gestureCurrentFontSize) >= 0.25 else { return }
                gestureCurrentFontSize = nextSize
                applyFontOnly(to: textView, size: nextSize)
            default:
                let finalSize = gestureCurrentFontSize
                if abs(finalSize - fontSize) > 0.01 {
                    fontSize = finalSize
                }
                gestureStartFontSize = finalSize
            }
        }

        func font() -> NSFont {
            SourceEditorFont.regular(size: fontSize)
        }

        fileprivate func repaintSyntaxOnly(in textView: NSTextView) {
            let size = appliedFontSize > 0 ? appliedFontSize : fontSize
            let font = SourceEditorFont.regular(size: size)
            TypstSyntaxHighlighter.applyTemporaryTokens(to: textView, text: textView.string, font: font)
            applyDiagnosticsAndSpelling(to: textView)
        }

        func applyHighlighting(to textView: NSTextView, text: String) {
            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let selectedRange = textView.selectedRange()
            let font = font()
            appliedFontSize = Double(font.pointSize)
            textView.font = font
            textView.typingAttributes = TypstSyntaxHighlighter.baseAttributes(font: font)

            if textView.string != text {
                textView.undoManager?.disableUndoRegistration()
                textView.textStorage?.setAttributedString(NSAttributedString(
                    string: text,
                    attributes: TypstSyntaxHighlighter.baseAttributes(font: font)
                ))
                textView.undoManager?.enableUndoRegistration()
            }

            TypstSyntaxHighlighter.applyTemporaryTokens(to: textView, text: text, font: font)
            applyDiagnosticsAndSpelling(to: textView)
            let textLength = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(
                location: min(selectedRange.location, textLength),
                length: min(selectedRange.length, max(0, textLength - min(selectedRange.location, textLength)))
            ))
        }

        private func applyFontOnly(to textView: NSTextView, size: Double) {
            let font = SourceEditorFont.regular(size: size)
            appliedFontSize = Double(font.pointSize)
            textView.font = font
            textView.typingAttributes = TypstSyntaxHighlighter.baseAttributes(font: font)

            TypstSyntaxHighlighter.applyTemporaryBaseFont(to: textView, font: font)
            applyDiagnosticsAndSpelling(to: textView)
        }

        private func applyDiagnosticsAndSpelling(to textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: textStorage.length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.toolTip, forCharacterRange: fullRange)

            if spellCheckingEnabled {
                for proseRange in proseRanges where NSMaxRange(proseRange.range) <= textStorage.length {
                    let text = (textStorage.string as NSString).substring(with: proseRange.range)
                    let misspelled = NSSpellChecker.shared.checkSpelling(
                        of: text,
                        startingAt: 0,
                        language: nil,
                        wrap: false,
                        inSpellDocumentWithTag: 0,
                        wordCount: nil
                    )
                    if misspelled.location != NSNotFound {
                        let range = NSRange(location: proseRange.range.location + misspelled.location, length: misspelled.length)
                        layoutManager.addTemporaryAttributes([
                            .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                            .underlineColor: NSColor.systemBlue,
                        ], forCharacterRange: range)
                    }
                }
            }

            for diagnostic in diagnostics where NSMaxRange(diagnostic.range) <= textStorage.length {
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], forCharacterRange: diagnostic.range.length == 0 ? NSRange(location: diagnostic.range.location, length: min(1, textStorage.length - diagnostic.range.location)) : diagnostic.range)
            }
        }

        private func insertPackageReference(path: String, at point: NSPoint, in textView: NSTextView) -> Bool {
            guard let snippet = snippet(for: path) else {
                sourceDropLogger.debug("macOS drop rejected: no snippet for path '\(path, privacy: .public)'. imagePaths=\(self.insertableImagePaths.count), typstPaths=\(self.insertableTypstPaths.count)")
                return false
            }

            let insertionIndex = textView.characterIndexForInsertion(at: point)
            let range = NSRange(location: insertionIndex, length: 0)
            sourceDropLogger.debug("macOS inserting snippet for path '\(path, privacy: .public)' at \(insertionIndex). snippet='\(snippet, privacy: .public)'")
            textView.setSelectedRange(range)
            textView.insertText(snippet, replacementRange: range)
            return true
        }

        private func importAndInsertExternalFile(_ url: URL, at point: NSPoint, in textView: NSTextView) -> Bool {
            guard let snippet = snippetForExternalFile(url) else {
                return false
            }

            let insertionIndex = textView.characterIndexForInsertion(at: point)
            let range = NSRange(location: insertionIndex, length: 0)
            sourceDropLogger.debug("macOS inserting external file snippet at \(insertionIndex). snippet='\(snippet, privacy: .public)'")
            textView.setSelectedRange(range)
            textView.insertText(snippet, replacementRange: range)
            return true
        }

        private func snippetForExternalFile(_ url: URL) -> String? {
            guard let packagePath = onImportExternalFile(url) else {
                sourceDropLogger.debug("macOS external file rejected: failed to import '\(url.path, privacy: .public)'")
                return nil
            }
            guard let snippet = SourceEditorDropSnippet.snippetForKnownPackagePath(packagePath, imageTemplate: imageInsertTemplate) else {
                sourceDropLogger.debug("macOS external file rejected: imported path has no snippet '\(packagePath, privacy: .public)'")
                return nil
            }
            return snippet
        }

        private func snippet(for path: String) -> String? {
            SourceEditorDropSnippet.snippet(
                for: path,
                imagePaths: insertableImagePaths,
                typstPaths: insertableTypstPaths,
                imageTemplate: imageInsertTemplate
            )
        }

    }

    final class PackagePathTextView: NSTextView {
        var onCompletionKey: ((NSEvent) -> Bool)?
        var onValidatePackagePathDrop: ((String) -> Bool)?
        var onPackagePathDropTargeted: ((Bool) -> Void)?
        var onDropPackagePath: ((String, NSPoint) -> Bool)?
        var onDropExternalFile: ((URL, NSPoint) -> Bool)?
        var onPasteExternalFile: ((URL) -> String?)?
        /// Reports user input that should release the post-open sticky scroll
        /// anchor (see `Coordinator.clearScrollAnchor`).
        var onUserInteraction: (() -> Void)?
        private var selectionBeforePackageDrag: NSRange?

        override func scrollWheel(with event: NSEvent) {
            onUserInteraction?()
            super.scrollWheel(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            onUserInteraction?()
            super.mouseDown(with: event)
        }

        /// `NSTextView` auto-scrolls during `setFrameSize:` (via the private
        /// `_setFrameSize:forceScroll:` → `_centeredScrollRectToVisible:`) to
        /// re-center the previous visual position whenever its frame changes.
        /// While a freshly opened document lays out, the frame grows in steps
        /// and that re-centering ratchets the view to the bottom, overriding
        /// the workspace's scroll restore. Preserve the scroll position across
        /// frame changes instead; intentional scrolling (user input,
        /// `scrollRangeToVisible`, the restore passes) is unaffected.
        override func setFrameSize(_ newSize: NSSize) {
            guard let clipView = superview as? NSClipView else {
                super.setFrameSize(newSize)
                return
            }
            let savedOrigin = clipView.bounds.origin
            super.setFrameSize(newSize)
            if clipView.bounds.origin != savedOrigin {
                let constrained = clipView.constrainBoundsRect(
                    NSRect(origin: savedOrigin, size: clipView.bounds.size)
                ).origin
                clipView.scroll(to: constrained)
                enclosingScrollView?.reflectScrolledClipView(clipView)
            }
        }

        override func keyDown(with event: NSEvent) {
            onUserInteraction?()
            if onCompletionKey?(event) == true {
                return
            }
            super.keyDown(with: event)
        }

        override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(paste(_:)),
               canPasteImportableContent(from: .general) {
                return true
            }
            return super.validateMenuItem(menuItem)
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)),
               canPasteImportableContent(from: .general) {
                return true
            }
            return super.validateUserInterfaceItem(item)
        }

        /// `NSTextView` only advertises plain-text types as pasteable when
        /// `isRichText` is false, which grays out the Paste menu item for
        /// image-only clipboards. This re-enables it whenever the clipboard
        /// holds something our `paste(_:)` override can actually import.
        private func canPasteImportableContent(from pasteboard: NSPasteboard) -> Bool {
            if pastedImageFile(from: pasteboard) != nil {
                return true
            }
            if let url = fileURL(from: pasteboard),
               SourceEditorDropSnippet.canCreateSnippet(forFileName: url.lastPathComponent) {
                return true
            }
            return false
        }

        override func paste(_ sender: Any?) {
            // For pasted images we write the bytes to a temporary file and then
            // route through the same code path as a file drag. That way every
            // image format Typst (and `SourceEditorDropSnippet.canCreateSnippet`)
            // already recognizes is supported automatically — no separate list.
            if let image = pastedImageFile(from: .general),
               let url = writePastedImageToTempFile(data: image.data, fileExtension: image.fileExtension),
               SourceEditorDropSnippet.canCreateSnippet(forFileName: url.lastPathComponent),
               let snippet = onPasteExternalFile?(url) {
                insertText(snippet, replacementRange: selectedRange())
                return
            }

            if let url = fileURL(from: .general),
               SourceEditorDropSnippet.canCreateSnippet(forFileName: url.lastPathComponent),
               let snippet = onPasteExternalFile?(url) {
                insertText(snippet, replacementRange: selectedRange())
                return
            }

            super.paste(sender)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = operation(for: sender)
            updateInsertionPoint(for: sender, operation: operation)
            return operation
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let operation = operation(for: sender)
            updateInsertionPoint(for: sender, operation: operation)
            return operation
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            finishPackageDrag(restoreSelection: true)
            super.draggingExited(sender)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            finishPackageDrag(restoreSelection: true)
            super.draggingEnded(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let operation = operation(for: sender)
            let isPrepared = operation != []
            sourceDropLogger.debug("macOS prepare drop: \(isPrepared)")
            return isPrepared || super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let path = packagePath(from: sender.draggingPasteboard) {
                let windowPoint = sender.draggingLocation
                let point = convert(windowPoint, from: nil)
                sourceDropLogger.debug("macOS perform drop decoded path '\(path, privacy: .public)' at point \(String(describing: point), privacy: .public)")
                let didDrop = onDropPackagePath?(path, point) == true
                finishPackageDrag(restoreSelection: false)
                sourceDropLogger.debug("macOS perform drop result for '\(path, privacy: .public)': \(didDrop)")
                return didDrop
            }

            guard let fileURL = fileURL(from: sender.draggingPasteboard) else {
                sourceDropLogger.debug("macOS perform drop: no package path. types=\(self.pasteboardTypesDescription(sender.draggingPasteboard), privacy: .public)")
                return super.performDragOperation(sender)
            }

            let windowPoint = sender.draggingLocation
            let point = convert(windowPoint, from: nil)
            sourceDropLogger.debug("macOS perform drop decoded external file '\(fileURL.path, privacy: .public)' at point \(String(describing: point), privacy: .public)")
            let didDrop = onDropExternalFile?(fileURL, point) == true
            finishPackageDrag(restoreSelection: false)
            sourceDropLogger.debug("macOS perform external file drop result for '\(fileURL.path, privacy: .public)': \(didDrop)")
            return didDrop
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            sourceDropLogger.debug("macOS conclude drop")
            super.concludeDragOperation(sender)
        }

        private func updateInsertionPoint(for sender: NSDraggingInfo, operation: NSDragOperation) {
            guard operation != [] else {
                finishPackageDrag(restoreSelection: true)
                return
            }

            if selectionBeforePackageDrag == nil {
                selectionBeforePackageDrag = selectedRange()
            }

            let point = convert(sender.draggingLocation, from: nil)
            let insertionIndex = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: insertionIndex, length: 0))
            scrollRangeToVisible(NSRange(location: insertionIndex, length: 0))
            onPackagePathDropTargeted?(true)
        }

        private func finishPackageDrag(restoreSelection: Bool) {
            if restoreSelection, let selectionBeforePackageDrag {
                setSelectedRange(selectionBeforePackageDrag)
            }
            selectionBeforePackageDrag = nil
            onPackagePathDropTargeted?(false)
        }

        private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
            guard let path = packagePath(from: sender.draggingPasteboard) else {
                if let fileURL = fileURL(from: sender.draggingPasteboard),
                   SourceEditorDropSnippet.canCreateSnippet(forFileName: fileURL.lastPathComponent) {
                    return .copy
                }

                sourceDropLogger.debug("macOS drag operation rejected: no package path or supported file URL. types=\(self.pasteboardTypesDescription(sender.draggingPasteboard), privacy: .public)")
                return super.draggingUpdated(sender)
            }

            guard onValidatePackagePathDrop?(path) == true else {
                sourceDropLogger.debug("macOS drag operation rejected: path '\(path, privacy: .public)' has no snippet target")
                return super.draggingUpdated(sender)
            }

            return .copy
        }

        private func pasteboardTypesDescription(_ pasteboard: NSPasteboard) -> String {
            pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? ""
        }

        private func fileURL(from pasteboard: NSPasteboard) -> URL? {
            if let url = NSURL(from: pasteboard) {
                return url as URL
            }

            let fileURLType = NSPasteboard.PasteboardType(UTType.fileURL.identifier)
            if let string = pasteboard.string(forType: fileURLType) ?? pasteboard.string(forType: .fileURL) {
                return URL(string: string)
            }

            return nil
        }

        /// Finds an image on the pasteboard in any format Typst can render and
        /// returns its bytes plus a filename extension. TIFF is converted to
        /// PNG since Typst doesn't render TIFF natively.
        private func pastedImageFile(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
            for type in pasteboard.types ?? [] {
                // Skip TIFF here; pasteboards often include it as a generic
                // fallback. Handled below by converting to PNG.
                if type == .tiff { continue }
                guard let uti = UTType(type.rawValue),
                      uti.conforms(to: .image),
                      let ext = uti.preferredFilenameExtension,
                      let data = pasteboard.data(forType: type) else { continue }
                return (data, ext)
            }

            if let tiffData = pasteboard.data(forType: .tiff),
               let representation = NSBitmapImageRep(data: tiffData),
               let pngData = representation.representation(using: .png, properties: [:]) {
                return (pngData, "png")
            }

            return nil
        }

        /// Writes pasted image bytes to a unique temporary directory so the
        /// drag-import code path can take it from there. The directory keeps
        /// the human-friendly filename ("Pasted Image.<ext>") collision-free.
        private func writePastedImageToTempFile(data: Data, fileExtension: String) -> URL? {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TypesetPastedImages", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = directory.appendingPathComponent("Pasted Image.\(fileExtension)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                return url
            } catch {
                sourceDropLogger.error("Failed to write pasted image to temp file: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        private func packagePath(from pasteboard: NSPasteboard) -> String? {
            let packageType = NSPasteboard.PasteboardType(UTType.typesetPackageFileDrag.identifier)
            if let data = pasteboard.data(forType: packageType),
               let item = try? JSONDecoder().decode(PackageFileDragItem.self, from: data) {
                sourceDropLogger.debug("macOS decoded package payload path '\(item.path, privacy: .public)'")
                return item.path
            }

            if fileURL(from: pasteboard) != nil {
                return nil
            }

            let plainTextType = NSPasteboard.PasteboardType(UTType.plainText.identifier)
            let fallbackPath = pasteboard.string(forType: plainTextType) ?? pasteboard.string(forType: .string)
            if let fallbackPath {
                sourceDropLogger.debug("macOS decoded fallback text path '\(fallbackPath, privacy: .public)'")
            }
            return fallbackPath
    }
}

final class LineNumberRulerView: NSRulerView {
        weak var textView: NSTextView?
        private let rulerWidth: CGFloat = 48

        init(textView: NSTextView) {
            self.textView = textView
            super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
            clientView = textView
            ruleThickness = rulerWidth
        }

        required init(coder: NSCoder) {
            super.init(coder: coder)
        }

        func invalidateLineNumbers() {
            needsDisplay = true
        }

        override func drawHashMarksAndLabels(in rect: NSRect) {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            NSColor.clear.setFill()
            rect.fill()

            let visibleRect = textView.visibleRect
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let text = textView.string as NSString
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .right
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]

            var glyphIndex = glyphRange.location
            while glyphIndex < NSMaxRange(glyphRange) {
                var lineRange = NSRange()
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
                let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
                let lineNumber = text.substring(to: min(characterIndex, text.length)).filter { $0 == "\n" }.count + 1
                let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
                let drawRect = NSRect(x: 4, y: y, width: rulerWidth - 10, height: lineRect.height)
                "\(lineNumber)".draw(in: drawRect, withAttributes: attributes)
                glyphIndex = NSMaxRange(lineRange)
            }
        }
    }
}
#endif

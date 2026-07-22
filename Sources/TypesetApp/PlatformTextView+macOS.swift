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
    var textReplacement: EditorTextReplacement?
    var insertableImagePaths: Set<String>
    var insertableTypstPaths: Set<String>
    var imageInsertTemplate: String
    var onImportExternalFile: @MainActor (URL) -> String?
    var onImportPastedImage: @MainActor (Data, String) -> String?
    var diagnostics: [TypstSourceDiagnostic]
    var proseRanges: [TypstProseRange]
    var proseRangesAreCurrent: Bool
    var showLineNumbers: Bool
    var spellCheckingEnabled: Bool
    var fixedTopContentInset: CGFloat?
    var onTextChange: (String, NSRange) -> Void
    var onSelectionChange: (NSRange) -> Void
    var isCompletionPresented: Bool
    var onCompletionMove: (Int) -> Void
    var onCompletionAccept: () -> Void
    var onCompletionDismiss: () -> Void
    var onShowFunctionHelp: (NSRange, CGPoint) -> Void
    var onShowSignatureHelp: (NSRange, CGPoint) -> Void
    var onGoToDefinition: (NSRange, CGPoint) -> Void
    var onFindReferences: (NSRange, CGPoint) -> Void
    var onRenameSymbol: (NSRange, CGPoint) -> Void
    var onShowCodeActions: (NSRange, CGPoint) -> Void
    var onEditorInteraction: () -> Void
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
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = spellCheckingEnabled
        textView.enabledTextCheckingTypes = spellCheckingEnabled ? Self.nativeTextCheckingTypes : 0
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
        textView.onCheckSpelling = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return false }
            return coordinator.checkSpelling(in: textView)
        }
        textView.onUserInteraction = { [weak coordinator = context.coordinator] in
            coordinator?.clearScrollAnchor()
            onEditorInteraction()
        }
        textView.onShowFunctionHelp = onShowFunctionHelp
        textView.onShowSignatureHelp = onShowSignatureHelp
        textView.isProseLocation = { [weak coordinator = context.coordinator] location in
            coordinator?.isProseLocation(location) ?? false
        }
        textView.onGoToDefinition = onGoToDefinition
        textView.onFindReferences = onFindReferences
        textView.onRenameSymbol = onRenameSymbol
        textView.onShowCodeActions = onShowCodeActions
        context.coordinator.configureDropHandling(for: textView)
        context.coordinator.applyHighlighting(to: textView, text: text)

        // In normal mode AppKit owns the toolbar/safe-area inset. In
        // distraction-free mode the toolbar itself is transient, so AppKit's
        // automatic inset changes as the toolbar shows/hides and fights the
        // fixed editor margin. Then the editor owns that top inset explicitly.
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        applyEditorContentInsets(to: scrollView)
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
        (textView as? PackagePathTextView)?.inlineDiagnostics = diagnostics
        context.coordinator.updateProseRanges(
            proseRanges,
            isCurrent: proseRangesAreCurrent,
            representedText: text
        )
        context.coordinator.spellCheckingEnabled = spellCheckingEnabled
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.isCompletionPresented = isCompletionPresented
        context.coordinator.onCompletionMove = onCompletionMove
        context.coordinator.onCompletionAccept = onCompletionAccept
        context.coordinator.onCompletionDismiss = onCompletionDismiss
        context.coordinator.onLanguageOverlayAnchorChange = onLanguageOverlayAnchorChange
        // Typeset paints spelling indicators itself, but lets AppKit own the
        // correction indicator and Escape-to-reject interaction. Delegate
        // filtering below limits native correction candidates to the language service's
        // semantic prose ranges.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        if textView.isAutomaticSpellingCorrectionEnabled != spellCheckingEnabled {
            textView.isAutomaticSpellingCorrectionEnabled = spellCheckingEnabled
        }
        let checkingTypes = spellCheckingEnabled ? Self.nativeTextCheckingTypes : 0
        if textView.enabledTextCheckingTypes != checkingTypes {
            textView.enabledTextCheckingTypes = checkingTypes
        }
        if let packageTextView = textView as? PackagePathTextView {
            packageTextView.onShowFunctionHelp = onShowFunctionHelp
            packageTextView.onShowSignatureHelp = onShowSignatureHelp
            packageTextView.isProseLocation = { [weak coordinator = context.coordinator] location in
                coordinator?.isProseLocation(location) ?? false
            }
            packageTextView.onGoToDefinition = onGoToDefinition
            packageTextView.onFindReferences = onFindReferences
            packageTextView.onRenameSymbol = onRenameSymbol
            packageTextView.onShowCodeActions = onShowCodeActions
            packageTextView.onUserInteraction = { [weak coordinator = context.coordinator] in
                coordinator?.clearScrollAnchor()
                onEditorInteraction()
            }
        }
        context.coordinator.isPackageDropTargeted = $isPackageDropTargeted
        context.coordinator.updateFontSize(fontSize, in: textView)
        textView.textContainerInset = NSSize(width: 18, height: 18)
        applyEditorContentInsets(to: scrollView)
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
        context.coordinator.applyTextReplacementIfNeeded(textReplacement, in: textView)
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
            proseRangesAreCurrent: proseRangesAreCurrent,
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

    private static let nativeTextCheckingTypes =
        NSTextCheckingResult.CheckingType.spelling.rawValue
            | NSTextCheckingResult.CheckingType.correction.rawValue

    private func applyEditorContentInsets(to scrollView: NSScrollView) {
        if let fixedTopContentInset {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(
                top: fixedTopContentInset,
                left: 0,
                bottom: 0,
                right: 0
            )
        } else {
            scrollView.automaticallyAdjustsContentInsets = true
            scrollView.contentInsets = NSEdgeInsetsZero
        }
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
        var proseRangesAreCurrent: Bool
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
        private var isApplyingPairEdit = false
        private var autocorrectionProseRanges: [TypstProseRange]
        private var autocorrectionTextLength: Int
        private var gestureStartFontSize = SourceEditorFont.defaultSize
        private var gestureCurrentFontSize = SourceEditorFont.defaultSize
        private var appliedFontSize = 0.0
        private var lastFocusRequest = 0
        private var lastCommentToggleRequest = 0
        private var lastSnippetToken = 0
        private var lastTextReplacementToken = 0
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
            proseRangesAreCurrent: Bool,
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
            self.proseRangesAreCurrent = proseRangesAreCurrent
            self.spellCheckingEnabled = spellCheckingEnabled
            self.autocorrectionProseRanges = proseRangesAreCurrent ? proseRanges : []
            self.autocorrectionTextLength = (text.wrappedValue as NSString).length
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

        func applyTextReplacementIfNeeded(_ request: EditorTextReplacement?, in textView: NSTextView) {
            guard let request, request.token != lastTextReplacementToken else { return }
            lastTextReplacementToken = request.token
            guard textView.isEditable else { return }
            let length = (textView.string as NSString).length
            let location = min(max(0, request.edit.replacementRange.location), length)
            let range = NSRange(
                location: location,
                length: min(max(0, request.edit.replacementRange.length), length - location)
            )
            textView.insertText(request.edit.replacementText, replacementRange: range)
            let nextLength = length - range.length + (request.edit.replacementText as NSString).length
            let selectionLocation = min(max(0, request.edit.selectedRange.location), nextLength)
            let selection = NSRange(
                location: selectionLocation,
                length: min(max(0, request.edit.selectedRange.length), nextLength - selectionLocation)
            )
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            updateLanguageOverlayAnchor(in: textView, selectedRange: selection)
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
            guard !isApplyingHighlighting, !isApplyingPairEdit else { return }
            guard let textView = notification.object as? NSTextView else { return }
            // Edits autoscroll to the caret (typing, paste via menu); the
            // user has taken over.
            clearScrollAnchor()
            let nextText = textView.string
            let nextLength = (nextText as NSString).length
            if nextLength != autocorrectionTextLength {
                proseRanges = []
                autocorrectionProseRanges = []
                autocorrectionTextLength = nextLength
            }
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
            (textView as? PackagePathTextView)?.diagnosticCaretDidChange()
        }

        func textView(
            _ textView: NSTextView,
            shouldSetSpellingState value: Int,
            range affectedCharRange: NSRange
        ) -> Int {
            // Native checking has no semantic-range API. Typeset renders its
            // own spelling state from the language service's prose ranges, so reject any
            // whole-document state AppKit attempts to install.
            0
        }

        func textView(
            _ textView: NSTextView,
            willCheckTextIn range: NSRange,
            options: [NSSpellChecker.OptionKey: Any],
            types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
        ) -> [NSSpellChecker.OptionKey: Any] {
            guard spellCheckingEnabled,
                  autocorrectionTextLength == (textView.string as NSString).length,
                  autocorrectionProseRanges.contains(where: { NSIntersectionRange($0.range, range).length > 0 })
            else {
                checkingTypes.pointee = 0
                return options
            }
            checkingTypes.pointee &= PlatformTextView.nativeTextCheckingTypes
            return options
        }

        func textView(
            _ textView: NSTextView,
            didCheckTextIn range: NSRange,
            types checkingTypes: NSTextCheckingTypes,
            options: [NSSpellChecker.OptionKey: Any],
            results: [NSTextCheckingResult],
            orthography: NSOrthography,
            wordCount: Int
        ) -> [NSTextCheckingResult] {
            guard spellCheckingEnabled,
                  autocorrectionTextLength == (textView.string as NSString).length
            else { return [] }
            return results.filter { result in
                let resultRange = result.range
                return resultRange.location != NSNotFound
                    && autocorrectionProseRanges.contains {
                        resultRange.location >= $0.range.location
                            && NSMaxRange(resultRange) <= NSMaxRange($0.range)
                    }
            }
        }

        func checkSpelling(in textView: NSTextView) -> Bool {
            let checker = NSSpellChecker.shared
            let text = textView.string
            let textLength = (text as NSString).length
            guard spellCheckingEnabled,
                  autocorrectionTextLength == textLength,
                  !autocorrectionProseRanges.isEmpty
            else {
                checker.updateSpellingPanel(withMisspelledWord: "")
                return false
            }

            let selection = textView.selectedRange()
            let searchStart = min(max(0, NSMaxRange(selection)), textLength)
            let ranges = spellingSearchRanges(startingAt: searchStart, textLength: textLength)
            let misspelledRange = ranges.lazy.compactMap { range -> NSRange? in
                let candidate = checker.checkSpelling(
                    of: text,
                    startingAt: range.location,
                    language: nil,
                    wrap: false,
                    inSpellDocumentWithTag: textView.spellCheckerDocumentTag,
                    wordCount: nil
                )
                guard candidate.location != NSNotFound,
                      candidate.location >= range.location,
                      NSMaxRange(candidate) <= NSMaxRange(range)
                else { return nil }
                return candidate
            }.first

            guard let misspelledRange else {
                checker.updateSpellingPanel(withMisspelledWord: "")
                return false
            }
            textView.setSelectedRange(misspelledRange)
            textView.scrollRangeToVisible(misspelledRange)
            checker.updateSpellingPanel(
                withMisspelledWord: (text as NSString).substring(with: misspelledRange)
            )
            return true
        }

        private func spellingSearchRanges(startingAt location: Int, textLength: Int) -> [NSRange] {
            let proseRanges = autocorrectionProseRanges
                .map(\.range)
                .filter {
                    $0.location != NSNotFound && $0.location >= 0 && NSMaxRange($0) <= textLength
                }
                .sorted { $0.location < $1.location }

            var forward: [NSRange] = []
            var wrapped: [NSRange] = []
            for range in proseRanges {
                let rangeEnd = NSMaxRange(range)
                if rangeEnd > location {
                    let start = max(location, range.location)
                    if start < rangeEnd {
                        forward.append(NSRange(location: start, length: rangeEnd - start))
                    }
                }
                if range.location < location {
                    let end = min(location, rangeEnd)
                    if range.location < end {
                        wrapped.append(NSRange(location: range.location, length: end - range.location))
                    }
                }
            }
            return forward + wrapped
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange, replacementString: String?) -> Bool {
            guard !isApplyingPairEdit,
                  textView.isEditable, !textView.hasMarkedText(),
                  let replacementString else { return true }
            let selectedRange = textView.selectedRange()

            if replacementString == "\n",
               affectedRange == selectedRange,
               let indentationEdit = SourceEditorSmartIndentation.editForNewline(
                in: textView.string,
                selectedRange: selectedRange
               ) {
                isApplyingPairEdit = true
                trackProseEdit(
                    replacing: indentationEdit.replacementRange,
                    with: indentationEdit.replacementText,
                    in: textView.string
                )
                textView.insertText(
                    indentationEdit.replacementText,
                    replacementRange: indentationEdit.replacementRange
                )
                textView.setSelectedRange(indentationEdit.selectedRange)
                isApplyingPairEdit = false
                textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
                return false
            }

            let pairEdit: SourceEditorTextEdit?
            if replacementString.isEmpty,
               selectedRange.length == 0,
               selectedRange.location > 0,
               affectedRange == NSRange(location: selectedRange.location - 1, length: 1) {
                // Plain backspace at a caret.
                pairEdit = SourceEditorBracketPairing.editForBackspace(in: textView.string, selectedRange: selectedRange)
            } else if affectedRange == selectedRange {
                // Plain typing at the live selection — pastes and drops replace
                // other ranges and pass through untouched.
                pairEdit = SourceEditorBracketPairing.edit(forTyping: replacementString, in: textView.string, selectedRange: selectedRange)
            } else {
                pairEdit = nil
            }
            guard let pairEdit else {
                trackProseEdit(replacing: affectedRange, with: replacementString, in: textView.string)
                return true
            }

            if pairEdit.isCaretMoveOnly {
                textView.setSelectedRange(pairEdit.selectedRange)
                return false
            }
            // `insertText(_:replacementRange:)` runs the standard editing
            // pipeline (undo registration, delegate callbacks); the flag stops
            // the nested shouldChangeText callback from re-pairing and holds the
            // textDidChange report until the caret is placed inside the pair —
            // the language pipeline reuses the selection captured with the text
            // change for its post-sync signature-help request, so reporting the
            // caret after the inserted closer would kill the parameter tooltip.
            isApplyingPairEdit = true
            trackProseEdit(
                replacing: pairEdit.replacementRange,
                with: pairEdit.replacementText,
                in: textView.string
            )
            textView.insertText(pairEdit.replacementText, replacementRange: pairEdit.replacementRange)
            textView.setSelectedRange(pairEdit.selectedRange)
            isApplyingPairEdit = false
            textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
            return false
        }

        func isProseLocation(_ location: Int) -> Bool {
            proseRanges.contains { NSLocationInRange(location, $0.range) }
        }

        func updateProseRanges(
            _ ranges: [TypstProseRange],
            isCurrent: Bool,
            representedText: String
        ) {
            proseRangesAreCurrent = isCurrent
            guard isCurrent else {
                let nativeText = textView?.string
                let nativeEditIsPending = nativeText.map { nativeTextAwaitingBinding == $0 } ?? false
                if let nativeText, nativeText != representedText, !nativeEditIsPending {
                    proseRanges = []
                    autocorrectionProseRanges = []
                    autocorrectionTextLength = (representedText as NSString).length
                }
                return
            }
            proseRanges = ranges
            autocorrectionProseRanges = ranges
            autocorrectionTextLength = (representedText as NSString).length
        }

        private func trackProseEdit(replacing range: NSRange, with replacement: String, in text: String) {
            let textLength = (text as NSString).length
            guard range.location != NSNotFound,
                  range.location >= 0,
                  NSMaxRange(range) <= textLength,
                  autocorrectionTextLength == textLength
            else {
                proseRanges = []
                autocorrectionProseRanges = []
                autocorrectionTextLength = max(0, textLength - max(0, range.length)) + (replacement as NSString).length
                return
            }
            let nextLength = textLength - range.length + (replacement as NSString).length
            guard SourceEditorAutocorrection.preservesSemanticClassification(
                replacing: range,
                with: replacement,
                in: text
            ) else {
                proseRanges = []
                autocorrectionProseRanges = []
                autocorrectionTextLength = nextLength
                return
            }
            let updatedRanges = SourceEditorAutocorrection.updating(
                autocorrectionProseRanges,
                replacing: range,
                with: replacement,
                textLength: textLength
            )
            proseRanges = updatedRanges
            proseRangesAreCurrent = false
            autocorrectionProseRanges = updatedRanges
            autocorrectionTextLength = nextLength
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
                if !proseRangesAreCurrent {
                    proseRanges = []
                }
                autocorrectionProseRanges = proseRangesAreCurrent ? proseRanges : []
                autocorrectionTextLength = (text as NSString).length
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
            // AppKit's native checker uses a separate temporary spelling-state
            // attribute, so clearing underline attributes alone leaves old
            // whole-document squiggles visible after Typeset takes ownership.
            layoutManager.removeTemporaryAttribute(.spellingState, forCharacterRange: fullRange)

            if spellCheckingEnabled {
                for proseRange in proseRanges where NSMaxRange(proseRange.range) <= textStorage.length {
                    let text = (textStorage.string as NSString).substring(with: proseRange.range)
                    let textLength = (text as NSString).length
                    var searchLocation = 0
                    while searchLocation < textLength {
                        let misspelled = NSSpellChecker.shared.checkSpelling(
                            of: text,
                            startingAt: searchLocation,
                            language: nil,
                            wrap: false,
                            inSpellDocumentWithTag: textView.spellCheckerDocumentTag,
                            wordCount: nil
                        )
                        guard misspelled.location != NSNotFound else { break }
                        let range = NSRange(location: proseRange.range.location + misspelled.location, length: misspelled.length)
                        // The genuine macOS spelling squiggle: the spelling-state
                        // temporary attribute makes AppKit draw its native red
                        // dotted underline, exactly like the system checker.
                        layoutManager.addTemporaryAttributes([
                            .spellingState: NSAttributedString.SpellingState.spelling.rawValue,
                        ], forCharacterRange: range)
                        let nextLocation = NSMaxRange(misspelled)
                        guard nextLocation > searchLocation else { break }
                        searchLocation = nextLocation
                    }
                }
            }

            // Underline only when the compiler gave a real span (>1 char). Point
            // diagnostics (line:column → length 1) get a triangle marker instead
            // — see `drawDiagnosticPointMarkers`.
            for diagnostic in diagnostics where diagnostic.range.length > 1 && NSMaxRange(diagnostic.range) <= textStorage.length {
                let color: NSColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                ], forCharacterRange: diagnostic.range)
            }
        }

        private func insertPackageReference(path: String, at point: NSPoint, in textView: NSTextView) -> Bool {
            guard let snippet = snippet(for: path) else {
                return false
            }

            let insertionIndex = textView.characterIndexForInsertion(at: point)
            let range = NSRange(location: insertionIndex, length: 0)
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
            textView.setSelectedRange(range)
            textView.insertText(snippet, replacementRange: range)
            return true
        }

        private func snippetForExternalFile(_ url: URL) -> String? {
            guard let packagePath = onImportExternalFile(url) else {
                return nil
            }
            guard let snippet = SourceEditorDropSnippet.snippetForKnownPackagePath(packagePath, imageTemplate: imageInsertTemplate) else {
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
        var onCheckSpelling: (() -> Bool)?
        var onShowFunctionHelp: ((NSRange, CGPoint) -> Void)?
        var onShowSignatureHelp: ((NSRange, CGPoint) -> Void)?
        /// Whether a character index falls inside prose (used to suppress
        /// keyword help for English words like "in" and "for").
        var isProseLocation: ((Int) -> Bool)?
        var onGoToDefinition: ((NSRange, CGPoint) -> Void)?
        var onFindReferences: ((NSRange, CGPoint) -> Void)?
        var onRenameSymbol: ((NSRange, CGPoint) -> Void)?
        var onShowCodeActions: ((NSRange, CGPoint) -> Void)?
        var onValidatePackagePathDrop: ((String) -> Bool)?
        var onPackagePathDropTargeted: ((Bool) -> Void)?
        var onDropPackagePath: ((String, NSPoint) -> Bool)?
        var onDropExternalFile: ((URL, NSPoint) -> Bool)?
        var onPasteExternalFile: ((URL) -> String?)?
        /// Reports user input that should release the post-open sticky scroll
        /// anchor (see `Coordinator.clearScrollAnchor`).
        var onUserInteraction: (() -> Void)?
        private var contextFunctionRange: NSRange?
        private var contextSymbolRange: NSRange?
        private var contextCodeActionRange: NSRange?
        private var selectionBeforePackageDrag: NSRange?

        /// Compiler diagnostics rendered inline: a faint full-width tint behind
        /// every line the diagnostic spans, plus a coloured message badge
        /// right-aligned at the trailing edge of the first spanned line.
        var inlineDiagnostics: [TypstSourceDiagnostic] = [] {
            didSet {
                guard inlineDiagnostics != oldValue else { return }
                needsDisplay = true
                updateDiagnosticToolTips()
            }
        }

        override func scrollWheel(with event: NSEvent) {
            onUserInteraction?()
            super.scrollWheel(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            onUserInteraction?()
            if event.modifierFlags.contains(.command) {
                let point = convert(event.locationInWindow, from: nil)
                let location = characterIndexForInsertion(at: point)
                if let range = SourceEditorSymbol.range(in: string, at: location) {
                    onGoToDefinition?(range, languageOverlayAnchor(for: range))
                    return
                }
            }
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
            // A width change reflows the badges (they're right-aligned), so their
            // tooltip rects must be re-registered. Runs after super sets the frame.
            let widthChanged = abs(newSize.width - frame.width) > 0.5
            defer { if widthChanged { updateDiagnosticToolTips() } }
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

        override func checkSpelling(_ sender: Any?) {
            guard let onCheckSpelling else {
                super.checkSpelling(sender)
                return
            }
            if onCheckSpelling(), !NSSpellChecker.shared.spellingPanel.isVisible {
                super.showGuessPanel(sender)
            }
        }

        override func showGuessPanel(_ sender: Any?) {
            let panel = NSSpellChecker.shared.spellingPanel
            let wasVisible = panel.isVisible
            super.showGuessPanel(sender)
            if !wasVisible, panel.isVisible {
                _ = onCheckSpelling?()
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for: event) ?? NSMenu()
            let point = convert(event.locationInWindow, from: nil)
            let location = characterIndexForInsertion(at: point)
            let actionRange = selectedRange().length > 0
                ? selectedRange()
                : NSRange(location: location, length: 0)
            contextCodeActionRange = actionRange
            let quickActions = NSMenuItem(
                title: "Quick Actions…",
                action: #selector(showCodeActions(_:)),
                keyEquivalent: ""
            )
            quickActions.target = self
            quickActions.representedObject = NSValue(range: actionRange)
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(quickActions, at: 0)

            guard let symbolRange = SourceEditorSymbol.range(in: string, at: location) else { return menu }
            contextSymbolRange = symbolRange
            let functionRange = SourceEditorSymbol.helpRange(
                in: string,
                at: location,
                isProse: isProseLocation?(location) == true
            )
            contextFunctionRange = functionRange

            let definition = NSMenuItem(
                title: "Go to Definition",
                action: #selector(goToDefinition(_:)),
                keyEquivalent: ""
            )
            definition.target = self
            definition.representedObject = NSValue(range: symbolRange)

            let references = NSMenuItem(
                title: "Find References",
                action: #selector(findReferences(_:)),
                keyEquivalent: ""
            )
            references.target = self
            references.representedObject = NSValue(range: symbolRange)

            let rename = NSMenuItem(
                title: "Rename Symbol…",
                action: #selector(renameSymbol(_:)),
                keyEquivalent: ""
            )
            rename.target = self
            rename.representedObject = NSValue(range: symbolRange)

            menu.insertItem(references, at: 0)
            menu.insertItem(rename, at: 0)
            menu.insertItem(definition, at: 0)

            guard let range = functionRange else { return menu }

            let help = NSMenuItem(
                title: "Show Function Help",
                action: #selector(showFunctionHelp(_:)),
                keyEquivalent: ""
            )
            help.target = self
            help.representedObject = NSValue(range: range)

            let signature = NSMenuItem(
                title: "Show Signature Help",
                action: #selector(showSignatureHelp(_:)),
                keyEquivalent: ""
            )
            signature.target = self
            signature.representedObject = NSValue(range: range)

            menu.insertItem(signature, at: 0)
            menu.insertItem(help, at: 0)
            return menu
        }

        @objc private func goToDefinition(_ sender: NSMenuItem) {
            performSymbolMenuAction(sender, action: onGoToDefinition)
        }

        @objc private func findReferences(_ sender: NSMenuItem) {
            performSymbolMenuAction(sender, action: onFindReferences)
        }

        @objc private func renameSymbol(_ sender: NSMenuItem) {
            performSymbolMenuAction(sender, action: onRenameSymbol)
        }

        @objc private func showCodeActions(_ sender: NSMenuItem) {
            let representedRange = (sender.representedObject as? NSValue)?.rangeValue
            guard let range = representedRange ?? contextCodeActionRange else { return }
            onShowCodeActions?(range, languageOverlayAnchor(for: range))
        }

        @objc private func showFunctionHelp(_ sender: NSMenuItem) {
            performFunctionMenuAction(sender, action: onShowFunctionHelp)
        }

        @objc private func showSignatureHelp(_ sender: NSMenuItem) {
            performFunctionMenuAction(sender, action: onShowSignatureHelp)
        }

        private func performFunctionMenuAction(
            _ sender: NSMenuItem,
            action: ((NSRange, CGPoint) -> Void)?
        ) {
            let representedRange = (sender.representedObject as? NSValue)?.rangeValue
            guard let range = representedRange ?? contextFunctionRange else { return }
            let anchor = languageOverlayAnchor(for: range)
            typesetLSPDebug(
                "native menu action=\(sender.title) range=\(range.location)..<\(NSMaxRange(range)) anchor=(\(anchor.x), \(anchor.y)) callback=\(action != nil)"
            )
            action?(range, anchor)
        }

        private func performSymbolMenuAction(
            _ sender: NSMenuItem,
            action: ((NSRange, CGPoint) -> Void)?
        ) {
            let representedRange = (sender.representedObject as? NSValue)?.rangeValue
            guard let range = representedRange ?? contextSymbolRange else { return }
            action?(range, languageOverlayAnchor(for: range))
        }

        private func languageOverlayAnchor(for range: NSRange) -> CGPoint {
            guard let layoutManager, let textContainer else { return .zero }
            let textLength = (string as NSString).length
            let location = min(max(0, range.location + range.length / 2), max(0, textLength - 1))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            let rect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            let origin = textContainerOrigin
            let visibleRect = visibleRect
            return CGPoint(
                x: rect.midX + origin.x - visibleRect.minX,
                y: rect.maxY + origin.y - visibleRect.minY
            )
        }

        override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(showFunctionHelp(_:))
                || menuItem.action == #selector(showSignatureHelp(_:))
                || menuItem.action == #selector(goToDefinition(_:))
                || menuItem.action == #selector(findReferences(_:))
                || menuItem.action == #selector(renameSymbol(_:))
                || menuItem.action == #selector(showCodeActions(_:)) {
                return true
            }
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

        // MARK: - Inline diagnostics

        override func draw(_ dirtyRect: NSRect) {
            drawDiagnosticHighlights(in: dirtyRect)
            super.draw(dirtyRect)
            drawDiagnosticPointMarkers(in: dirtyRect)
            drawDiagnosticBadges(in: dirtyRect)
        }

        /// Full-width rects for every line the diagnostic spans, plus the first
        /// spanned line's fragment rect (the badge anchor). In the text view's
        /// flipped coordinate space. `nil` when the range no longer fits the text
        /// (it can lag a fast edit until fresh diagnostics arrive).
        private func diagnosticRects(for diagnostic: TypstSourceDiagnostic) -> (lines: [NSRect], badgeLine: NSRect)? {
            guard let layoutManager, let textStorage, textStorage.length > 0 else { return nil }
            let length = textStorage.length
            var charRange = diagnostic.range
            if charRange.length == 0 {
                charRange = NSRange(location: min(charRange.location, length - 1), length: 1)
            }
            guard charRange.location >= 0, NSMaxRange(charRange) <= length else { return nil }

            // Expand to the full source line(s), minus the trailing terminator, so a
            // wrapped line tints all of its visual lines — not just the fragment the
            // range happens to touch.
            let string = textStorage.string as NSString
            var lineStart = 0
            var contentsEnd = 0
            string.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: charRange)
            let highlightRange = contentsEnd > lineStart
                ? NSRange(location: lineStart, length: contentsEnd - lineStart)
                : charRange

            let glyphRange = layoutManager.glyphRange(forCharacterRange: highlightRange, actualCharacterRange: nil)
            let origin = textContainerOrigin
            var lines: [NSRect] = []
            var badgeLine = NSRect.zero
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragmentRect, _, _, _, _ in
                let shifted = fragmentRect.offsetBy(dx: origin.x, dy: origin.y)
                lines.append(NSRect(x: 0, y: shifted.minY, width: self.bounds.width, height: shifted.height))
                badgeLine = shifted // last fragment wins → badge on the final visual line
            }
            guard !lines.isEmpty else { return nil }
            return (lines, badgeLine)
        }

        private func drawDiagnosticHighlights(in dirtyRect: NSRect) {
            for diagnostic in inlineDiagnostics {
                guard let rects = diagnosticRects(for: diagnostic) else { continue }
                let tint = diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemYellow
                tint.withAlphaComponent(0.10).setFill()
                for line in rects.lines where line.intersects(dirtyRect) {
                    NSBezierPath(rect: line).fill()
                }
            }
        }

        /// For point diagnostics (no usable span, `range.length <= 1`), draw a
        /// small severity-coloured triangle at the foot of the character pointing
        /// up at the error location — clearer than a one-character underline.
        private func drawDiagnosticPointMarkers(in dirtyRect: NSRect) {
            guard let layoutManager, let textContainer, let textStorage else { return }
            let length = textStorage.length
            let markerHeight: CGFloat = 5
            let markerHalfWidth: CGFloat = 4.5
            for diagnostic in inlineDiagnostics where diagnostic.range.length <= 1 {
                let location = diagnostic.range.location
                guard location >= 0, location < length else { continue }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: location, length: 1),
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += textContainerOrigin.x
                rect.origin.y += textContainerOrigin.y
                let centerX = rect.midX
                let baseY = rect.maxY
                let markerRect = NSRect(
                    x: centerX - markerHalfWidth,
                    y: baseY - markerHeight,
                    width: markerHalfWidth * 2,
                    height: markerHeight
                )
                guard markerRect.intersects(dirtyRect) else { continue }

                let path = NSBezierPath()
                path.move(to: NSPoint(x: centerX, y: baseY - markerHeight)) // apex (up)
                path.line(to: NSPoint(x: centerX - markerHalfWidth, y: baseY))
                path.line(to: NSPoint(x: centerX + markerHalfWidth, y: baseY))
                path.close()
                (diagnostic.severity == .error ? NSColor.systemRed : NSColor.systemYellow).setFill()
                path.fill()
            }
        }

        private struct DiagnosticBadgeLayout {
            let rect: NSRect
            let message: String
            let isError: Bool
            let isTruncated: Bool
        }

        private static let badgeHorizontalPadding: CGFloat = 7
        private static let badgeVerticalPadding: CGFloat = 2

        /// Measurement attributes (no colour — that doesn't affect size and is
        /// applied per badge at draw time).
        private func diagnosticBadgeTextAttributes() -> [NSAttributedString.Key: Any] {
            let badgeFont = NSFont.systemFont(ofSize: max(9, (font?.pointSize ?? 12) - 2), weight: .medium)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            return [.font: badgeFont, .paragraphStyle: paragraph]
        }

        private func diagnosticBadgeLayouts() -> [DiagnosticBadgeLayout] {
            guard !inlineDiagnostics.isEmpty else { return [] }
            let horizontalInset = textContainerInset.width
            let attributes = diagnosticBadgeTextAttributes()
            let hPad = Self.badgeHorizontalPadding
            let vPad = Self.badgeVerticalPadding
            let caretLine = diagnosticCaretLineRange()

            return inlineDiagnostics.compactMap { diagnostic in
                // The diagnostic on the caret's line shows as a callout above the
                // caret instead, so suppress its inline badge here.
                if let caretLine, self.diagnosticIsOnLine(diagnostic, line: caretLine) { return nil }
                guard let rects = diagnosticRects(for: diagnostic) else { return nil }
                let measured = (diagnostic.message as NSString).size(withAttributes: attributes)
                let maxWidth = max(80, bounds.width * 0.6)
                let fullWidth = measured.width.rounded(.up) + hPad * 2
                let badgeWidth = min(fullWidth, maxWidth)
                let badgeHeight = measured.height.rounded(.up) + vPad * 2
                let rect = NSRect(
                    x: bounds.width - horizontalInset - badgeWidth,
                    y: rects.badgeLine.midY - badgeHeight / 2,
                    width: badgeWidth,
                    height: badgeHeight
                )
                return DiagnosticBadgeLayout(
                    rect: rect,
                    message: diagnostic.message,
                    isError: diagnostic.severity == .error,
                    isTruncated: fullWidth > maxWidth
                )
            }
        }

        private func drawDiagnosticBadges(in dirtyRect: NSRect) {
            var attributes = diagnosticBadgeTextAttributes()
            let inset = NSSize(width: Self.badgeHorizontalPadding, height: Self.badgeVerticalPadding)
            for badge in diagnosticBadgeLayouts() where badge.rect.intersects(dirtyRect) {
                (badge.isError ? NSColor.systemRed : NSColor.systemYellow).setFill()
                NSBezierPath(roundedRect: badge.rect, xRadius: 5, yRadius: 5).fill()
                attributes[.foregroundColor] = badge.isError ? NSColor.white : NSColor.black
                (badge.message as NSString).draw(
                    in: badge.rect.insetBy(dx: inset.width, dy: inset.height),
                    withAttributes: attributes
                )
            }
        }

        /// Register a hover tooltip carrying the full text for any badge whose
        /// message is truncated, so the rest stays readable on hover.
        private func updateDiagnosticToolTips() {
            removeAllToolTips()
            for badge in diagnosticBadgeLayouts() where badge.isTruncated {
                addToolTip(badge.rect, owner: badge.message as NSString, userData: nil)
            }
        }

        private func diagnosticCaretLineRange() -> NSRange? {
            guard let textStorage else { return nil }
            let caret = min(max(0, selectedRange().location), textStorage.length)
            return (textStorage.string as NSString).lineRange(for: NSRange(location: caret, length: 0))
        }

        private func diagnosticIsOnLine(_ diagnostic: TypstSourceDiagnostic, line: NSRange) -> Bool {
            guard let textStorage, diagnostic.range.location <= textStorage.length else { return false }
            let string = textStorage.string as NSString
            let safe = NSRange(
                location: diagnostic.range.location,
                length: min(diagnostic.range.length, string.length - diagnostic.range.location)
            )
            return NSIntersectionRange(line, string.lineRange(for: safe)).length > 0
        }

        /// The caret moved: re-evaluate which badge is suppressed (the one on the
        /// caret's line, now shown as a callout) and refresh tooltip rects.
        func diagnosticCaretDidChange() {
            needsDisplay = true
            updateDiagnosticToolTips()
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
            return isPrepared || super.prepareForDragOperation(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let path = packagePath(from: sender.draggingPasteboard) {
                let windowPoint = sender.draggingLocation
                let point = convert(windowPoint, from: nil)
                let didDrop = onDropPackagePath?(path, point) == true
                finishPackageDrag(restoreSelection: false)
                return didDrop
            }

            guard let fileURL = fileURL(from: sender.draggingPasteboard) else {
                return super.performDragOperation(sender)
            }

            let windowPoint = sender.draggingLocation
            let point = convert(windowPoint, from: nil)
            let didDrop = onDropExternalFile?(fileURL, point) == true
            finishPackageDrag(restoreSelection: false)
            return didDrop
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
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

                return super.draggingUpdated(sender)
            }

            guard onValidatePackagePathDrop?(path) == true else {
                return super.draggingUpdated(sender)
            }

            return .copy
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
                return item.path
            }

            if fileURL(from: pasteboard) != nil {
                return nil
            }

            let plainTextType = NSPasteboard.PasteboardType(UTType.plainText.identifier)
            return pasteboard.string(forType: plainTextType) ?? pasteboard.string(forType: .string)
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

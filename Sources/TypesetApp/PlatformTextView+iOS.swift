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

#if !os(macOS)
struct PlatformTextView: UIViewRepresentable {
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
    var fixedTopContentInset: CGFloat?
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

    func makeUIView(context: Context) -> UITextView {
        let textView = PackageTextView()
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.font = context.coordinator.font()
        textView.delegate = context.coordinator
        textView.textDropDelegate = context.coordinator
        // Dedicated drop interaction for raw image data (Photos, etc.), which
        // the text drop delegate above doesn't receive.
        textView.addInteraction(UIDropInteraction(delegate: context.coordinator))
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
        // Pinch-to-zoom is intentionally not installed: the editor font size is
        // controlled from Settings instead, so a stray pinch can't rescale the
        // code (and won't fight the document/preview gestures).
        textView.onPasteImage = { [weak coordinator = context.coordinator] data, suggestedName in
            coordinator?.snippetForPastedImage(data: data, suggestedName: suggestedName)
        }
        textView.onPasteExternalFile = { [weak coordinator = context.coordinator] url in
            coordinator?.snippetForExternalFile(url)
        }
        textView.onCompletionKey = { [weak coordinator = context.coordinator] action in
            coordinator?.handleCompletionKey(action) == true
        }
        textView.isCompletionPresented = isCompletionPresented
        context.coordinator.textView = textView
        context.coordinator.applyHighlighting(to: textView, text: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.textView = textView
        context.coordinator.insertableImagePaths = insertableImagePaths
        context.coordinator.insertableTypstPaths = insertableTypstPaths
        context.coordinator.imageInsertTemplate = imageInsertTemplate
        context.coordinator.onImportExternalFile = onImportExternalFile
        context.coordinator.onImportPastedImage = onImportPastedImage
        context.coordinator.diagnostics = diagnostics
        (textView as? PackageTextView)?.inlineDiagnostics = diagnostics
        context.coordinator.proseRanges = proseRanges
        context.coordinator.spellCheckingEnabled = spellCheckingEnabled
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.isCompletionPresented = isCompletionPresented
        context.coordinator.onCompletionMove = onCompletionMove
        context.coordinator.onCompletionAccept = onCompletionAccept
        context.coordinator.onCompletionDismiss = onCompletionDismiss
        context.coordinator.onScrollOffsetChange = onScrollOffsetChange
        context.coordinator.onLanguageOverlayAnchorChange = onLanguageOverlayAnchorChange
        if let packageTextView = textView as? PackageTextView {
            packageTextView.onPasteImage = { [weak coordinator = context.coordinator] data, suggestedName in
                coordinator?.snippetForPastedImage(data: data, suggestedName: suggestedName)
            }
            packageTextView.onPasteExternalFile = { [weak coordinator = context.coordinator] url in
                coordinator?.snippetForExternalFile(url)
            }
            packageTextView.onCompletionKey = { [weak coordinator = context.coordinator] action in
                coordinator?.handleCompletionKey(action) == true
            }
            packageTextView.isCompletionPresented = isCompletionPresented
        }
        context.coordinator.isPackageDropTargeted = $isPackageDropTargeted
        context.coordinator.updateFontSize(fontSize, in: textView)
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
        (textView as? PackageTextView)?.fixedTopContentInset = fixedTopContentInset ?? 0
        let annotationsChanged = context.coordinator.consumeAnnotationChanges(
            diagnostics: diagnostics,
            proseRanges: proseRanges,
            spellCheckingEnabled: spellCheckingEnabled
        )

        if textView.text != text {
            if context.coordinator.shouldKeepNativeText(textView.text, representedText: text) {
                context.coordinator.scheduleRepaint(in: textView)
            } else {
                context.coordinator.applyHighlighting(to: textView, text: text)
            }
        } else {
            context.coordinator.markRepresentedTextSynced(text)
            if annotationsChanged {
                context.coordinator.scheduleRepaint(in: textView)
            }
        }
        textView.isEditable = isEditable

        if let selectedRange, textView.selectedRange != selectedRange {
            textView.selectedRange = selectedRange
            textView.scrollRangeToVisible(selectedRange)
            DispatchQueue.main.async {
                self.selectedRange = nil
            }
        }
        context.coordinator.toggleCommentIfNeeded(commentToggleRequest, in: textView)
        context.coordinator.insertSnippetIfNeeded(snippetInsertion, in: textView)
        context.coordinator.focusIfNeeded(focusRequest, textView: textView)
        context.coordinator.onScrollFractionChange = onScrollFractionChange
        context.coordinator.restoreScrollIfNeeded(scrollRestore, in: textView)
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
            onScrollOffsetChange: onScrollOffsetChange,
            onLanguageOverlayAnchorChange: onLanguageOverlayAnchorChange,
            isPackageDropTargeted: $isPackageDropTargeted
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UITextDropDelegate, UIDropInteractionDelegate {
        @Binding var text: String
        @Binding var fontSize: Double
        weak var textView: UITextView?
        var onScrollFractionChange: ((Double) -> Void)?
        private var lastScrollRestoreToken = 0
        private var isRestoringScroll = false
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
        var onScrollOffsetChange: (CGFloat) -> Void
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
        private var scheduledRepaintWorkItem: DispatchWorkItem?
        private var renderedDiagnostics: [TypstSourceDiagnostic] = []
        private var renderedProseRanges: [TypstProseRange] = []
        private var renderedSpellCheckingEnabled = false
        private var lastSentSelection = NSRange(location: NSNotFound, length: 0)
        private var lastLanguageOverlayAnchor: CGPoint?

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
            onScrollOffsetChange: @escaping (CGFloat) -> Void,
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
            self.onScrollOffsetChange = onScrollOffsetChange
            self.onLanguageOverlayAnchorChange = onLanguageOverlayAnchorChange
            self.isPackageDropTargeted = isPackageDropTargeted
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            let nextText = textView.text ?? ""
            let range = textView.selectedRange
            scheduleRepaint(in: textView)
            sendTextChange(nextText, selectedRange: range)
            updateLanguageOverlayAnchor(in: textView, selectedRange: range)
        }

        func focusIfNeeded(_ focusRequest: Int, textView: UITextView) {
            guard focusRequest != lastFocusRequest else { return }
            lastFocusRequest = focusRequest
            focus(textView, remainingAttempts: 4)
        }

        func toggleCommentIfNeeded(_ commentToggleRequest: Int, in textView: UITextView) {
            guard commentToggleRequest != lastCommentToggleRequest else { return }
            lastCommentToggleRequest = commentToggleRequest
            guard textView.isEditable else { return }
            guard let edit = SourceEditorCommentToggle.edit(
                for: textView.text,
                selectedRange: textView.selectedRange
            ) else { return }
            guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.replacementRange.location),
                  let end = textView.position(from: start, offset: edit.replacementRange.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }

            textView.replace(textRange, withText: edit.replacementText)
            textView.selectedRange = edit.selectedRange
            textView.scrollRangeToVisible(edit.selectedRange)
            updateLanguageOverlayAnchor(in: textView, selectedRange: edit.selectedRange)
        }

        func insertSnippetIfNeeded(_ request: EditorSnippetInsertion?, in textView: UITextView) {
            guard let request, request.token != lastSnippetToken else { return }
            lastSnippetToken = request.token
            guard textView.isEditable else { return }
            let selectedRange = textView.selectedRange
            let selectedText = (textView.text as NSString).substring(with: selectedRange)
            let resolved = SourceEditorDropSnippet.resolveInsertion(
                request.template,
                fallback: request.fallback,
                selectedText: selectedText
            )
            guard let start = textView.position(from: textView.beginningOfDocument, offset: selectedRange.location),
                  let end = textView.position(from: start, offset: selectedRange.length),
                  let textRange = textView.textRange(from: start, to: end)
            else { return }

            // replace(_:withText:) registers the edit with the text view's undo
            // manager and fires textViewDidChange to sync the binding.
            textView.replace(textRange, withText: resolved.text)
            let newSelection = NSRange(
                location: selectedRange.location + resolved.selectionLocation,
                length: resolved.selectionLength
            )
            textView.selectedRange = newSelection
            textView.scrollRangeToVisible(newSelection)
            updateLanguageOverlayAnchor(in: textView, selectedRange: newSelection)
        }

        private func focus(_ textView: UITextView, remainingAttempts: Int) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard textView.window != nil else {
                    if remainingAttempts > 0 {
                        self.focus(textView, remainingAttempts: remainingAttempts - 1)
                    }
                    return
                }
                textView.becomeFirstResponder()
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingHighlighting else { return }
            let range = textView.selectedRange
            sendSelectionChange(range)
            updateLanguageOverlayAnchor(in: textView, selectedRange: range)
            (textView as? PackageTextView)?.rebuildDiagnosticDecorations()
        }

        private func sendTextChange(_ nextText: String, selectedRange range: NSRange) {
            nativeTextAwaitingBinding = nextText
            lastSentSelection = range
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
            guard !NSEqualRanges(lastSentSelection, range) else { return }
            lastSentSelection = range
            DispatchQueue.main.async { [weak self] in
                self?.onSelectionChange(range)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            onScrollOffsetChange(scrollView.contentOffset.y)
            if let textView = scrollView as? UITextView {
                updateLanguageOverlayAnchor(in: textView, selectedRange: textView.selectedRange)
            }
            if !isRestoringScroll {
                let maxScroll = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                let fraction = maxScroll > 0
                    ? Double(min(1, max(0, scrollView.contentOffset.y / maxScroll)))
                    : 0
                onScrollFractionChange?(fraction)
            }
        }

        func restoreScrollIfNeeded(_ request: SourceEditorScrollRestore?, in textView: UITextView) {
            guard let request, request.token != lastScrollRestoreToken else { return }
            lastScrollRestoreToken = request.token
            isRestoringScroll = true
            if request.revealSelection {
                revealSelection(request.selection ?? NSRange(location: 0, length: 0), in: textView)
            } else {
                applyRestoreScroll(fraction: min(1, max(0, request.fraction)), selection: request.selection, in: textView, attemptsRemaining: 4, previousMaxScroll: -1)
            }
        }

        /// Restores the vertical scroll to `fraction` of the *settled* scrollable
        /// range. UITextView reports an estimated (often inflated) `contentSize`
        /// before it finishes laying out a freshly set string; multiplying a
        /// saved fraction by that estimate overshoots past the real content and
        /// leaves the viewport blank with all the text scrolled above it. We
        /// force layout, clamp to the measured range, and re-measure on later
        /// passes until the content height stabilizes.
        private func applyRestoreScroll(
            fraction: Double,
            selection: NSRange?,
            in textView: UITextView,
            attemptsRemaining: Int,
            previousMaxScroll: CGFloat
        ) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.layoutIfNeeded()
                if let selection {
                    let length = (textView.text as NSString).length
                    let location = min(max(0, selection.location), length)
                    let len = min(selection.length, max(0, length - location))
                    textView.selectedRange = NSRange(location: location, length: len)
                }
                let maxScroll = max(0, textView.contentSize.height - textView.bounds.height)
                let target = min(maxScroll, max(0, maxScroll * CGFloat(fraction)))
                textView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                if attemptsRemaining > 0, abs(maxScroll - previousMaxScroll) > 0.5 {
                    self.applyRestoreScroll(
                        fraction: fraction,
                        selection: nil,
                        in: textView,
                        attemptsRemaining: attemptsRemaining - 1,
                        previousMaxScroll: maxScroll
                    )
                } else {
                    DispatchQueue.main.async { self.isRestoringScroll = false }
                }
            }
        }

        /// Selects `requestedRange` and scrolls it into view (centered), used for
        /// "jump to match" navigation. Re-applies across passes until the content
        /// height stabilizes — on a cross-file jump the text view is freshly
        /// mounted and `scrollRangeToVisible` against a not-yet-settled
        /// `contentSize` often no-ops, leaving the match off-screen at the top.
        /// Clears `isRestoringScroll` on the final pass.
        private func revealSelection(_ requestedRange: NSRange, in textView: UITextView) {
            applyReveal(requestedRange, in: textView, attemptsRemaining: 4, previousMaxScroll: -1)
        }

        private func applyReveal(_ requestedRange: NSRange, in textView: UITextView, attemptsRemaining: Int, previousMaxScroll: CGFloat) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.layoutIfNeeded()
                let length = (textView.text as NSString).length
                let location = min(max(0, requestedRange.location), length)
                let len = min(requestedRange.length, max(0, length - location))
                let range = NSRange(location: location, length: len)
                textView.selectedRange = range
                textView.scrollRangeToVisible(range)
                let maxScroll = max(0, textView.contentSize.height - textView.bounds.height)
                // Center the match using the caret rect when layout is ready.
                if let start = textView.position(from: textView.beginningOfDocument, offset: range.location) {
                    let caret = textView.caretRect(for: start)
                    if caret.midY.isFinite {
                        let target = min(maxScroll, max(0, caret.midY - textView.bounds.height / 2))
                        textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: target), animated: false)
                    }
                }
                if attemptsRemaining > 0, abs(maxScroll - previousMaxScroll) > 0.5 {
                    self.applyReveal(range, in: textView, attemptsRemaining: attemptsRemaining - 1, previousMaxScroll: maxScroll)
                } else {
                    DispatchQueue.main.async { self.isRestoringScroll = false }
                }
            }
        }

        func handleCompletionKey(_ action: PackageTextView.CompletionKeyAction) -> Bool {
            guard isCompletionPresented else { return false }
            switch action {
            case .moveDown:
                onCompletionMove(1)
            case .moveUp:
                onCompletionMove(-1)
            case .accept:
                onCompletionAccept()
            case .dismiss:
                onCompletionDismiss()
            }
            return true
        }

        private func updateLanguageOverlayAnchor(in textView: UITextView, selectedRange: NSRange) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: selectedRange.location) else { return }
            let rect = textView.caretRect(for: start)
            let anchor = CGPoint(
                x: rect.minX - textView.contentOffset.x,
                y: rect.maxY - textView.contentOffset.y
            )
            if let lastLanguageOverlayAnchor, lastLanguageOverlayAnchor.distance(to: anchor) <= 0.5 {
                return
            }
            lastLanguageOverlayAnchor = anchor
            onLanguageOverlayAnchorChange(anchor)
        }

        func consumeAnnotationChanges(
            diagnostics: [TypstSourceDiagnostic],
            proseRanges: [TypstProseRange],
            spellCheckingEnabled: Bool
        ) -> Bool {
            let changed = renderedDiagnostics != diagnostics ||
                renderedProseRanges != proseRanges ||
                renderedSpellCheckingEnabled != spellCheckingEnabled
            renderedDiagnostics = diagnostics
            renderedProseRanges = proseRanges
            renderedSpellCheckingEnabled = spellCheckingEnabled
            return changed
        }

        func scheduleRepaint(in textView: UITextView, delay: TimeInterval = 0.12) {
            scheduledRepaintWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard !self.isApplyingHighlighting else { return }
                self.repaintSyntaxOnly(in: textView)
            }
            scheduledRepaintWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        func updateFontSize(_ newSize: Double, in textView: UITextView) {
            let clampedSize = SourceEditorFont.clamped(newSize)
            if abs(clampedSize - fontSize) > 0.01 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, abs(self.fontSize - clampedSize) > 0.01 else { return }
                    self.fontSize = clampedSize
                }
            }
            guard abs(appliedFontSize - clampedSize) > 0.01 else { return }
            applyHighlighting(to: textView, text: textView.text)
        }

        func font() -> UIFont {
            SourceEditorFont.regular(size: fontSize)
        }

        fileprivate func repaintSyntaxOnly(in textView: UITextView) {
            let size = appliedFontSize > 0 ? appliedFontSize : fontSize
            let font = SourceEditorFont.regular(size: size)
            TypstSyntaxHighlighter.applyTemporaryTokens(to: textView, text: textView.text, font: font)
            applyDiagnosticsAndSpelling(to: textView)
        }

        func applyHighlighting(to textView: UITextView, text: String) {
            isApplyingHighlighting = true
            defer { isApplyingHighlighting = false }

            let selectedRange = textView.selectedRange
            let font = font()
            appliedFontSize = Double(font.pointSize)
            textView.font = font
            textView.typingAttributes = TypstSyntaxHighlighter.baseAttributes(font: font)

            if textView.text != text {
                textView.attributedText = NSAttributedString(
                    string: text,
                    attributes: TypstSyntaxHighlighter.baseAttributes(font: font)
                )
            }

            TypstSyntaxHighlighter.applyTemporaryTokens(to: textView, text: text, font: font)
            applyDiagnosticsAndSpelling(to: textView)
            let textLength = (textView.text as NSString).length
            textView.selectedRange = NSRange(
                location: min(selectedRange.location, textLength),
                length: min(selectedRange.length, max(0, textLength - min(selectedRange.location, textLength)))
            )
        }

        private func applyFontOnly(to textView: UITextView, size: Double) {
            let font = SourceEditorFont.regular(size: size)
            appliedFontSize = Double(font.pointSize)
            textView.font = font
            textView.typingAttributes = TypstSyntaxHighlighter.baseAttributes(font: font)

            guard textView.textStorage.length > 0 else { return }
            textView.textStorage.beginEditing()
            textView.textStorage.addAttribute(.font, value: font, range: NSRange(location: 0, length: textView.textStorage.length))
            textView.textStorage.endEditing()
            applyDiagnosticsAndSpelling(to: textView)
        }

        private func applyDiagnosticsAndSpelling(to textView: UITextView) {
            guard textView.textStorage.length > 0 else { return }
            let fullRange = NSRange(location: 0, length: textView.textStorage.length)
            textView.textStorage.beginEditing()
            textView.textStorage.removeAttribute(.underlineStyle, range: fullRange)
            textView.textStorage.removeAttribute(.underlineColor, range: fullRange)

            if spellCheckingEnabled {
                let checker = UITextChecker()
                for proseRange in proseRanges where NSMaxRange(proseRange.range) <= textView.textStorage.length {
                    let misspelled = checker.rangeOfMisspelledWord(
                        in: textView.text,
                        range: proseRange.range,
                        startingAt: proseRange.range.location,
                        wrap: false,
                        language: ""
                    )
                    if misspelled.location != NSNotFound {
                        textView.textStorage.addAttributes([
                            .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                            .underlineColor: UIColor.systemBlue,
                        ], range: misspelled)
                    }
                }
            }

            // Underline only for a real span (>1 char); point diagnostics get a
            // triangle marker in `rebuildDiagnosticDecorations` instead.
            for diagnostic in diagnostics where diagnostic.range.length > 1 && NSMaxRange(diagnostic.range) <= textView.textStorage.length {
                let color: UIColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                textView.textStorage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                ], range: diagnostic.range)
            }
            textView.textStorage.endEditing()
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
            guard canInsertPackagePath(from: drop) else {
                sourceDropLogger.debug("iOS drop proposal rejected. item count=\(drop.dropSession.items.count)")
                isPackageDropTargeted.wrappedValue = false
                return UITextDropProposal(operation: .cancel)
            }

            if let textView = textDroppableView as? UITextView {
                updateInsertionPoint(at: drop.dropPosition, in: textView)
            }
            sourceDropLogger.debug("iOS drop proposal accepted. item count=\(drop.dropSession.items.count)")
            isPackageDropTargeted.wrappedValue = true
            let proposal = UITextDropProposal(operation: .copy)
            proposal.dropAction = .insert
            return proposal
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
            guard let textView = textDroppableView as? UITextView else {
                sourceDropLogger.debug("iOS willPerformDrop: target was not UITextView")
                return
            }

            sourceDropLogger.debug("iOS willPerformDrop with \(drop.dropSession.items.count) item(s)")
            for item in drop.dropSession.items {
                loadPackageDrop(from: item.itemProvider) { [weak self, weak textView] dropItem in
                    guard let dropItem else {
                        sourceDropLogger.debug("iOS drop item produced no path")
                        return
                    }

                    Task { @MainActor in
                        guard let self, let textView else { return }
                        guard let snippet = self.snippet(for: dropItem) else {
                            sourceDropLogger.debug("iOS drop rejected: no snippet for path '\(dropItem.path, privacy: .public)'. imagePaths=\(self.insertableImagePaths.count), typstPaths=\(self.insertableTypstPaths.count)")
                            return
                        }
                        sourceDropLogger.debug("iOS inserting snippet for path '\(dropItem.path, privacy: .public)'. snippet='\(snippet, privacy: .public)'")
                        self.insertSnippet(snippet, at: drop.dropPosition, in: textView)
                        self.isPackageDropTargeted.wrappedValue = false
                    }
                }
            }
        }

        private func canInsertPackagePath(from drop: UITextDropRequest) -> Bool {
            // The dedicated UIDropInteraction handles image / file / package
            // drags. Let the text view perform its own drop only for content
            // that is none of those — otherwise the snippet and the dragged
            // path both get inserted.
            drop.dropSession.items.allSatisfy { item in
                let provider = item.itemProvider
                return !provider.hasItemConformingToTypeIdentifier(UTType.typesetPackageFileDrag.identifier)
                    && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    && Self.imageTypeIdentifier(for: provider) == nil
            }
        }

        private enum LoadedDropItem: Sendable {
            case packagePath(String)
            case externalFile(URL)

            var path: String {
                switch self {
                case .packagePath(let path):
                    return path
                case .externalFile(let url):
                    return url.path
                }
            }
        }

        private func loadPackageDrop(from provider: NSItemProvider, completion: @escaping @Sendable (LoadedDropItem?) -> Void) {
            if provider.hasItemConformingToTypeIdentifier(UTType.typesetPackageFileDrag.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.typesetPackageFileDrag.identifier) { data, _ in
                    let item = data.flatMap { try? JSONDecoder().decode(PackageFileDragItem.self, from: $0) }
                    if let path = item?.path {
                        sourceDropLogger.debug("iOS decoded package payload path '\(path, privacy: .public)'")
                        completion(.packagePath(path))
                    } else {
                        sourceDropLogger.debug("iOS failed to decode package payload")
                        completion(nil)
                    }
                }
                return
            }

            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error {
                        sourceDropLogger.debug("iOS failed to decode file URL: \(error.localizedDescription, privacy: .public)")
                        completion(nil)
                        return
                    }
                    let url: URL?
                    if let itemURL = item as? URL {
                        url = itemURL
                    } else if let itemURL = item as? NSURL {
                        url = itemURL as URL
                    } else if let data = item as? Data,
                              let string = String(data: data, encoding: .utf8) {
                        url = URL(string: string)
                    } else if let string = item as? String {
                        url = URL(string: string)
                    } else {
                        url = nil
                    }

                    if let url {
                        sourceDropLogger.debug("iOS decoded external file URL '\(url.path, privacy: .public)'")
                        completion(.externalFile(url))
                    } else {
                        sourceDropLogger.debug("iOS failed to decode external file URL")
                        completion(nil)
                    }
                }
                return
            }

            if let imageTypeIdentifier = Self.imageTypeIdentifier(for: provider) {
                provider.loadDataRepresentation(forTypeIdentifier: imageTypeIdentifier) { data, _ in
                    guard let data,
                          let url = Self.writeDroppedImageToTempFile(data: data, typeIdentifier: imageTypeIdentifier) else {
                        sourceDropLogger.debug("iOS failed to materialize dropped image data")
                        completion(nil)
                        return
                    }
                    completion(.externalFile(url))
                }
                return
            }

            guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
                sourceDropLogger.debug("iOS provider has no package or plain text representation")
                completion(nil)
                return
            }

            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                let path = data.flatMap { String(data: $0, encoding: .utf8) }
                if let path {
                    sourceDropLogger.debug("iOS decoded fallback text path '\(path, privacy: .public)'")
                    completion(.packagePath(path))
                } else {
                    sourceDropLogger.debug("iOS failed to decode fallback text path")
                    completion(nil)
                }
            }
        }

        /// First registered type identifier that is an image format Typst can
        /// render. TIFF is skipped — Typst doesn't render it.
        private static func imageTypeIdentifier(for provider: NSItemProvider) -> String? {
            for identifier in provider.registeredTypeIdentifiers {
                guard let type = UTType(identifier),
                      type.conforms(to: .image),
                      type != .tiff else { continue }
                return identifier
            }
            return nil
        }

        nonisolated private static func writeDroppedImageToTempFile(data: Data, typeIdentifier: String) -> URL? {
            let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? "png"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TypesetDroppedImages", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = directory.appendingPathComponent("Dropped Image.\(fileExtension)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url)
                return url
            } catch {
                sourceDropLogger.error("iOS failed to write dropped image: \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        // MARK: - UIDropInteractionDelegate (image / file / package drops)
        //
        // `UITextDropDelegate` always makes the text view insert the dragged
        // item's own text representation (e.g. a file's path), so routing
        // snippet-producing drops through it double-inserts. Image, file-URL,
        // and package drags are therefore handled here instead, where the
        // insertion is fully custom; `canInsertPackagePath` above rejects the
        // same sessions so the text view doesn't also act on them. Plain text
        // is left to the text view's default drop handling.

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            canImportSession(session)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: canImportSession(session) ? .copy : .cancel)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let textView = interaction.view as? UITextView else { return }
            let dropPoint = session.location(in: textView)
            for item in session.items {
                loadPackageDrop(from: item.itemProvider) { [weak self, weak textView] dropItem in
                    guard let dropItem else {
                        sourceDropLogger.debug("iOS drop: item produced no path")
                        return
                    }
                    Task { @MainActor in
                        guard let self, let textView else { return }
                        guard let snippet = self.snippet(for: dropItem) else {
                            sourceDropLogger.debug("iOS drop: no snippet for '\(dropItem.path, privacy: .public)'")
                            return
                        }
                        if let position = textView.closestPosition(to: dropPoint) {
                            self.insertSnippet(snippet, at: position, in: textView)
                        } else {
                            textView.insertText(snippet)
                        }
                    }
                }
            }
        }

        /// True when every dragged item is something the editor imports —
        /// an image, a file URL, or an internal package-file drag.
        private func canImportSession(_ session: UIDropSession) -> Bool {
            guard !session.items.isEmpty else { return false }
            return session.items.allSatisfy { item in
                let provider = item.itemProvider
                return Self.imageTypeIdentifier(for: provider) != nil
                    || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.typesetPackageFileDrag.identifier)
            }
        }

        private func insertSnippet(_ snippet: String, at position: UITextPosition, in textView: UITextView) {
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            let range = NSRange(location: max(0, offset), length: 0)
            sourceDropLogger.debug("iOS inserting at offset \(range.location)")
            textView.selectedRange = range
            textView.insertText(snippet)
        }

        private func updateInsertionPoint(at position: UITextPosition, in textView: UITextView) {
            let offset = textView.offset(from: textView.beginningOfDocument, to: position)
            textView.selectedRange = NSRange(location: max(0, offset), length: 0)
        }

        private func snippet(for path: String) -> String? {
            SourceEditorDropSnippet.snippet(
                for: path,
                imagePaths: insertableImagePaths,
                typstPaths: insertableTypstPaths,
                imageTemplate: imageInsertTemplate
            )
        }

        private func snippet(for dropItem: LoadedDropItem) -> String? {
            switch dropItem {
            case .packagePath(let path):
                return snippet(for: path)
            case .externalFile(let url):
                return snippetForExternalFile(url)
            }
        }

        fileprivate func snippetForExternalFile(_ url: URL) -> String? {
            guard let packagePath = onImportExternalFile(url) else {
                sourceDropLogger.debug("iOS external file rejected: failed to import '\(url.path, privacy: .public)'")
                return nil
            }
            return SourceEditorDropSnippet.snippetForKnownPackagePath(packagePath, imageTemplate: imageInsertTemplate)
        }

        fileprivate func snippetForPastedImage(data: Data, suggestedName: String) -> String? {
            guard let packagePath = onImportPastedImage(data, suggestedName) else {
                sourceDropLogger.debug("iOS paste rejected: failed to import pasted image '\(suggestedName, privacy: .public)'")
                return nil
            }
            return SourceEditorDropSnippet.snippetForKnownPackagePath(packagePath, imageTemplate: imageInsertTemplate)
        }
    }

    final class PackageTextView: UITextView {
        enum CompletionKeyAction {
            case moveDown
            case moveUp
            case accept
            case dismiss
        }

        var onPasteImage: ((Data, String) -> String?)?
        var onPasteExternalFile: ((URL) -> String?)?
        var onCompletionKey: ((CompletionKeyAction) -> Bool)?
        var isCompletionPresented = false

        /// Compiler diagnostics rendered inline. UITextView lays out (and
        /// scrolls) text in content-space sublayers, so decorations are overlay
        /// subviews positioned via UITextInput geometry: a faint full-width tint
        /// behind every spanned line, and a coloured message badge on top,
        /// right-aligned at the first spanned line's trailing edge.
        var inlineDiagnostics: [TypstSourceDiagnostic] = [] {
            didSet {
                guard inlineDiagnostics != oldValue else { return }
                rebuildDiagnosticDecorations()
            }
        }
        private var diagnosticHighlightViews: [UIView] = []
        private var diagnosticBadgeViews: [UIView] = []
        private var lastDecorationLayoutWidth: CGFloat = 0

        /// A floor applied over the safe-area top inset, so distraction-free mode
        /// pushes the code below the windowed-app controls overlaying the top.
        var fixedTopContentInset: CGFloat = 0 {
            didSet {
                guard fixedTopContentInset != oldValue else { return }
                applySafeAreaScrollInsets()
            }
        }

        override init(frame: CGRect, textContainer: NSTextContainer?) {
            super.init(frame: frame, textContainer: textContainer)
            // Manage the top scroll inset ourselves. UIKit's automatic
            // adjustment computes `adjustedContentInset.top` from the
            // safe-area at first layout — but when this view is rebuilt
            // via `.id(selectedPath)` on file switch, SwiftUI sometimes
            // hosts it for a frame with `safeAreaInsets == .zero` before
            // the parent propagates the real value. The automatic
            // mechanism then locks the zero value in and the text scrolls
            // up underneath the toolbar with no top margin. Doing the
            // adjustment by hand re-applies the correct inset on every
            // `safeAreaInsetsDidChange` / `layoutSubviews` pass.
            contentInsetAdjustmentBehavior = .never
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var canBecomeFirstResponder: Bool {
            true
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            applySafeAreaScrollInsets()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applySafeAreaScrollInsets()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applySafeAreaScrollInsets()
            // Text reflows when the content width changes (rotation, split view);
            // rebuild then. Otherwise the overlay subviews scroll with the
            // content for free. Re-assert z-order every pass so text fragments
            // added/removed during scroll don't cover the badges or sit behind
            // the highlights.
            if abs(bounds.width - lastDecorationLayoutWidth) > 0.5 {
                lastDecorationLayoutWidth = bounds.width
                rebuildDiagnosticDecorations()
            }
            for highlight in diagnosticHighlightViews { sendSubviewToBack(highlight) }
            for badge in diagnosticBadgeViews { bringSubviewToFront(badge) }
        }

        func rebuildDiagnosticDecorations() {
            for view in diagnosticHighlightViews { view.removeFromSuperview() }
            for view in diagnosticBadgeViews { view.removeFromSuperview() }
            diagnosticHighlightViews.removeAll()
            diagnosticBadgeViews.removeAll()
            guard !inlineDiagnostics.isEmpty, textStorage.length > 0 else { return }

            let contentWidth = bounds.width
            let badgeFont = UIFont.systemFont(ofSize: max(9, (font?.pointSize ?? 12) - 2), weight: .medium)
            let horizontalPadding: CGFloat = 7
            let verticalPadding: CGFloat = 2
            let caretLine = diagnosticCaretLineRange()

            for diagnostic in inlineDiagnostics {
                guard let geometry = diagnosticGeometry(for: diagnostic) else { continue }
                let isError = diagnostic.severity == .error

                let tint = (isError ? UIColor.systemRed : .systemYellow).withAlphaComponent(0.10)
                for lineRect in geometry.lines {
                    let highlight = UIView(frame: lineRect)
                    highlight.backgroundColor = tint
                    highlight.isUserInteractionEnabled = false
                    insertSubview(highlight, at: 0)
                    diagnosticHighlightViews.append(highlight)
                }

                // Point diagnostics (no usable span) get a triangle marker at the
                // foot of the character instead of a one-character underline.
                if diagnostic.range.length <= 1, let charRect = diagnosticPointMarkerRect(for: diagnostic) {
                    let marker = makeDiagnosticTriangle(charRect: charRect, isError: isError)
                    addSubview(marker)
                    diagnosticBadgeViews.append(marker)
                }

                // The diagnostic on the caret's line shows as a callout above the
                // caret instead; keep its highlight but skip the badge.
                if let caretLine, diagnosticIsOnLine(diagnostic, line: caretLine) { continue }

                let label = UILabel()
                label.text = diagnostic.message
                label.font = badgeFont
                label.textColor = isError ? .white : .black
                label.lineBreakMode = .byTruncatingTail
                let measured = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                let maxWidth = max(80, contentWidth * 0.6)
                let fullWidth = measured.width.rounded(.up) + horizontalPadding * 2
                let badgeWidth = min(fullWidth, maxWidth)
                let badgeHeight = measured.height.rounded(.up) + verticalPadding * 2
                let badge = UIView(frame: CGRect(
                    x: contentWidth - textContainerInset.right - badgeWidth,
                    y: geometry.badgeLine.midY - badgeHeight / 2,
                    width: badgeWidth,
                    height: badgeHeight
                ))
                badge.backgroundColor = isError ? UIColor.systemRed : .systemYellow
                badge.layer.cornerRadius = 5
                badge.isUserInteractionEnabled = false
                label.frame = badge.bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                badge.addSubview(label)
                if fullWidth > maxWidth {
                    // Full message on pointer hover (iPad) when the badge truncates.
                    badge.isUserInteractionEnabled = true
                    badge.addInteraction(UIToolTipInteraction(defaultToolTip: diagnostic.message))
                }
                addSubview(badge)
                diagnosticBadgeViews.append(badge)
            }
        }

        private func diagnosticCaretLineRange() -> NSRange? {
            let caret = min(max(0, selectedRange.location), textStorage.length)
            return (textStorage.string as NSString).lineRange(for: NSRange(location: caret, length: 0))
        }

        private func diagnosticIsOnLine(_ diagnostic: TypstSourceDiagnostic, line: NSRange) -> Bool {
            guard diagnostic.range.location <= textStorage.length else { return false }
            let string = textStorage.string as NSString
            let safe = NSRange(
                location: diagnostic.range.location,
                length: min(diagnostic.range.length, string.length - diagnostic.range.location)
            )
            return NSIntersectionRange(line, string.lineRange(for: safe)).length > 0
        }

        private func diagnosticPointMarkerRect(for diagnostic: TypstSourceDiagnostic) -> CGRect? {
            let location = diagnostic.range.location
            guard location >= 0, location < textStorage.length,
                  let start = position(from: beginningOfDocument, offset: location),
                  let end = position(from: start, offset: 1),
                  let range = textRange(from: start, to: end) else { return nil }
            let rect = firstRect(for: range)
            guard rect.width.isFinite, rect.height > 0, rect.minY.isFinite else { return nil }
            return rect
        }

        private func makeDiagnosticTriangle(charRect: CGRect, isError: Bool) -> UIView {
            let markerHeight: CGFloat = 5
            let markerHalfWidth: CGFloat = 4.5
            let marker = UIView(frame: CGRect(
                x: charRect.midX - markerHalfWidth,
                y: charRect.maxY - markerHeight,
                width: markerHalfWidth * 2,
                height: markerHeight
            ))
            marker.backgroundColor = .clear
            marker.isUserInteractionEnabled = false
            let triangle = UIBezierPath()
            triangle.move(to: CGPoint(x: markerHalfWidth, y: 0)) // apex (up)
            triangle.addLine(to: CGPoint(x: 0, y: markerHeight))
            triangle.addLine(to: CGPoint(x: markerHalfWidth * 2, y: markerHeight))
            triangle.close()
            let shape = CAShapeLayer()
            shape.path = triangle.cgPath
            shape.fillColor = (isError ? UIColor.systemRed : .systemYellow).cgColor
            marker.layer.addSublayer(shape)
            return marker
        }

        /// Full-width rects for every line the diagnostic spans plus the first
        /// line's rect (badge anchor), in content coordinates. Uses UITextInput
        /// geometry, so it works whether the view is backed by TextKit 1 or 2.
        private func diagnosticGeometry(for diagnostic: TypstSourceDiagnostic) -> (lines: [CGRect], badgeLine: CGRect)? {
            let length = textStorage.length
            guard length > 0, diagnostic.range.location >= 0, diagnostic.range.location < length else { return nil }
            let baseLen = min(diagnostic.range.length == 0 ? 1 : diagnostic.range.length, length - diagnostic.range.location)
            let charRange = NSRange(location: diagnostic.range.location, length: baseLen)

            // Expand to the full source line(s), minus the trailing terminator, so a
            // wrapped line tints all of its visual lines.
            let string = textStorage.string as NSString
            var lineStart = 0
            var contentsEnd = 0
            string.getLineStart(&lineStart, end: nil, contentsEnd: &contentsEnd, for: charRange)
            let highlightRange = contentsEnd > lineStart
                ? NSRange(location: lineStart, length: contentsEnd - lineStart)
                : charRange

            guard let start = position(from: beginningOfDocument, offset: highlightRange.location),
                  let end = position(from: start, offset: highlightRange.length),
                  let range = textRange(from: start, to: end) else { return nil }
            let rects = selectionRects(for: range)
                .map(\.rect)
                .filter { $0.height > 0 && $0.minY.isFinite && $0.width.isFinite }
            guard !rects.isEmpty else { return nil }
            var lines: [CGRect] = []
            for rect in rects where !lines.contains(where: { abs($0.minY - rect.minY) < 1 }) {
                lines.append(CGRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height))
            }
            // Badge on the last (bottom-most) visual line.
            guard let badgeLine = rects.max(by: { $0.minY < $1.minY }) else { return nil }
            return (lines, badgeLine)
        }

        private func applySafeAreaScrollInsets() {
            let desiredTop = max(safeAreaInsets.top, fixedTopContentInset)
            let desiredBottom = safeAreaInsets.bottom

            if abs(contentInset.top - desiredTop) > 0.5 ||
                abs(contentInset.bottom - desiredBottom) > 0.5 {
                contentInset.top = desiredTop
                contentInset.bottom = desiredBottom
            }

            var indicator = verticalScrollIndicatorInsets
            if abs(indicator.top - desiredTop) > 0.5 ||
                abs(indicator.bottom - desiredBottom) > 0.5 {
                indicator.top = desiredTop
                indicator.bottom = desiredBottom
                verticalScrollIndicatorInsets = indicator
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard isCompletionPresented else { return super.keyCommands }
            return [
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(moveCompletionDown)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(moveCompletionUp)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(acceptCompletion)),
                UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(acceptCompletion)),
                UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissCompletion)),
            ] + (super.keyCommands ?? [])
        }

        @objc private func moveCompletionDown() {
            _ = onCompletionKey?(.moveDown)
        }

        @objc private func moveCompletionUp() {
            _ = onCompletionKey?(.moveUp)
        }

        @objc private func acceptCompletion() {
            _ = onCompletionKey?(.accept)
        }

        @objc private func dismissCompletion() {
            _ = onCompletionKey?(.dismiss)
        }

        override func paste(_ sender: Any?) {
            if let image = UIPasteboard.general.image,
               let data = image.pngData(),
               let snippet = onPasteImage?(data, "Pasted Image.png") {
                insertText(snippet)
                return
            }

            if let url = UIPasteboard.general.urls?.first,
               SourceEditorDropSnippet.canCreateSnippet(forFileName: url.lastPathComponent),
               let snippet = onPasteExternalFile?(url) {
                insertText(snippet)
                return
            }

            super.paste(sender)
        }
    }

    struct LineNumberGutter: View {
        var text: String
        var scrollOffset: CGFloat

        private var lineCount: Int {
            max(1, text.filter { $0 == "\n" }.count + 1)
        }

        var body: some View {
            ScrollView(.vertical) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(1...lineCount, id: \.self) { line in
                        Text("\(line)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, height: 20, alignment: .trailing)
                    }
                }
                .padding(.top, 18)
                .padding(.trailing, 6)
                .offset(y: -scrollOffset)
            }
            .scrollDisabled(true)
            .frame(width: 48)
            .background(.quaternary.opacity(0.18))
        }
    }
}
#endif

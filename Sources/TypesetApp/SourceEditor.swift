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

nonisolated let sourceDropLogger = Logger(subsystem: "com.twarge.typeset", category: "SourceDrop")

/// Debug flag — set to `false` to verify the iOS "loses focus every keystroke"
/// problem is the LSP popovers restructuring SwiftUI's view tree mid-typing.
/// If focus stays put with this off, the fix is to keep the overlay's
/// structure stable (always rendered, hidden via opacity rather than
/// inserted/removed); if focus is still lost, the cause is elsewhere.
private let kSourceEditorLanguageOverlayEnabled = true

/// Debug flag — set to `false` to stop writing the iOS scroll offset to
/// `@State` on every scroll/keystroke. The gutter will stop tracking the
/// text view's scroll; if the AttributeGraph cycle warnings disappear, the
/// per-keystroke scroll write is the cycle source.
private let kSourceEditorScrollOffsetTrackingEnabled = true

/// Debug flag — set to `false` to stop writing the LSP overlay anchor to
/// `@State` on every text change/selection move/scroll. The overlay (if
/// enabled) will sit at a default anchor; if the cycle warnings disappear,
/// the per-keystroke anchor update is the loop.
private let kSourceEditorOverlayAnchorTrackingEnabled = true

/// A one-shot request to insert a snippet template through the text view (so it
/// is registered with the text view's undo manager and can wrap the selection).
/// `token` changes to trigger a new insertion.
struct EditorSnippetInsertion: Equatable {
    var token: Int
    var template: String
    var fallback: String
}

/// A one-shot request to restore the editor to a saved position: a vertical
/// scroll `fraction` (0...1 of the scrollable range) and, optionally, the caret
/// `selection`. The `token` distinguishes a fresh request from a repeat so the
/// editor applies it once. Both are applied after layout settles; the selection
/// is set *without* scrolling to it, so the saved scroll position wins.
struct SourceEditorScrollRestore: Equatable {
    var token: Int
    var fraction: Double
    var selection: NSRange?
    /// When `true`, ignore `fraction` and instead scroll `selection` into view
    /// (centered) — used for "jump to match" navigation (Find results) where the
    /// destination file's saved scroll position must yield to the revealed match.
    /// Folded into the same token so it can never race a normal restore.
    var revealSelection = false
}

struct SourceEditor: View {
    @Binding var text: String
    @Binding var selectedRange: NSRange?
    var isEditable: Bool
    var focusRequest = 0
    var commentToggleRequest = 0
    var snippetInsertion: EditorSnippetInsertion?
    var insertableImagePaths: Set<String> = []
    var insertableTypstPaths: Set<String> = []
    var imageInsertTemplate = SourceEditorDropSnippet.defaultImageTemplate
    var onImportExternalFile: @MainActor (URL) -> String? = { _ in nil }
    var onImportPastedImage: @MainActor (Data, String) -> String? = { _, _ in nil }
    var diagnostics: [TypstSourceDiagnostic] = []
    var proseRanges: [TypstProseRange] = []
    var proseRangesAreCurrent = true
    var completions: [TypstCompletionItem] = []
    var hoverInfo: TypstHoverInfo?
    var cursorDiagnostic: TypstSourceDiagnostic?
    var signatureHelp: TypstSignatureHelp?
    var selectedCompletionIndex = 0
    var showLineNumbers = false
    var spellCheckingEnabled = true
    var fixedTopContentInset: CGFloat?
    var onTextChange: (String, NSRange) -> Void = { _, _ in }
    var onSelectionChange: (NSRange) -> Void = { _ in }
    var onCompletionSelected: (TypstCompletionItem) -> Void = { _ in }
    var onCompletionMove: (Int) -> Void = { _ in }
    var onCompletionAccept: () -> Void = {}
    var onCompletionDismiss: () -> Void = {}
    var onShowFunctionHelp: (NSRange) -> Void = { _ in }
    var onShowSignatureHelp: (NSRange) -> Void = { _ in }
    var onEditorInteraction: () -> Void = {}
    var onScrollFractionChange: (Double) -> Void = { _ in }
    var scrollRestore: SourceEditorScrollRestore?

    // Persisted and shared with the Settings pane (same key), so the editor
    // font size is adjustable from preferences on both platforms.
    @AppStorage("sourceEditor.fontSize") private var fontSize = SourceEditorFont.defaultSize
    @State private var isPackageDropTargeted = false
    @State private var iosScrollOffset: CGFloat = 0
    @State private var languageOverlayAnchor = CGPoint(x: 12, y: 34)

    var body: some View {
        let editor = PlatformTextView(
            text: $text,
            selectedRange: $selectedRange,
            isEditable: isEditable,
            focusRequest: focusRequest,
            commentToggleRequest: commentToggleRequest,
            snippetInsertion: snippetInsertion,
            insertableImagePaths: insertableImagePaths,
            insertableTypstPaths: insertableTypstPaths,
            imageInsertTemplate: imageInsertTemplate,
            onImportExternalFile: onImportExternalFile,
            onImportPastedImage: onImportPastedImage,
            diagnostics: diagnostics,
            proseRanges: proseRanges,
            proseRangesAreCurrent: proseRangesAreCurrent,
            showLineNumbers: showLineNumbers,
            spellCheckingEnabled: spellCheckingEnabled,
            fixedTopContentInset: fixedTopContentInset,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange,
            isCompletionPresented: !completions.isEmpty,
            onCompletionMove: onCompletionMove,
            onCompletionAccept: onCompletionAccept,
            onCompletionDismiss: onCompletionDismiss,
            onShowFunctionHelp: { range, anchor in
                languageOverlayAnchor = anchor
                onShowFunctionHelp(range)
            },
            onShowSignatureHelp: { range, anchor in
                languageOverlayAnchor = anchor
                onShowSignatureHelp(range)
            },
            onEditorInteraction: onEditorInteraction,
            onScrollOffsetChange: { offset in
                guard kSourceEditorScrollOffsetTrackingEnabled else { return }
                DispatchQueue.main.async {
                    guard abs(iosScrollOffset - offset) > 0.5 else { return }
                    iosScrollOffset = offset
                }
            },
            onLanguageOverlayAnchorChange: { anchor in
                guard kSourceEditorOverlayAnchorTrackingEnabled else { return }
                // Defer so the @State mutation doesn't land inside a SwiftUI
                // view update (the representable reports the anchor during
                // updateNSView), which triggers an "undefined behavior" warning.
                DispatchQueue.main.async {
                    guard languageOverlayAnchor.distance(to: anchor) > 0.5 else { return }
                    languageOverlayAnchor = anchor
                }
            },
            onScrollFractionChange: onScrollFractionChange,
            scrollRestore: scrollRestore,
            isPackageDropTargeted: $isPackageDropTargeted,
            fontSize: $fontSize
        )
        .font(.system(.body, design: .monospaced))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(.tint.opacity(isPackageDropTargeted ? 0.75 : 0), lineWidth: 2)
                .background(.tint.opacity(isPackageDropTargeted ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
                .animation(.snappy(duration: 0.18), value: isPackageDropTargeted)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            // DEBUG: flip `kSourceEditorLanguageOverlayEnabled` (top of file)
            // to `false` to isolate the iOS focus-loss-per-keystroke issue —
            // the overlay's body restructures (empty ↔ populated panel) as
            // LSP results arrive, which can knock the UITextView out of
            // first-responder on iOS.
            if kSourceEditorLanguageOverlayEnabled {
                SourceEditorLanguageOverlay(
                    completions: completions,
                    hoverInfo: hoverInfo,
                    cursorDiagnostic: cursorDiagnostic,
                    signatureHelp: signatureHelp,
                    selectedCompletionIndex: selectedCompletionIndex,
                    fontSize: fontSize,
                    anchor: languageOverlayAnchor,
                    onCompletionSelected: onCompletionSelected,
                    onCompletionDismiss: onCompletionDismiss
                )
            }
        }

        #if os(macOS)
        editor
        #else
        HStack(spacing: 0) {
            if showLineNumbers {
                PlatformTextView.LineNumberGutter(text: text, scrollOffset: iosScrollOffset)
            }
            editor
        }
        #endif
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

enum SourceEditorFont {
    static let defaultSize = 15.0
    static let minimumSize = 11.0
    static let maximumSize = 30.0
    static let bundledFontFileNames = [
        "FiraCode-Light",
        "FiraCode-Regular",
        "FiraCode-Retina",
        "FiraCode-Medium",
        "FiraCode-SemiBold",
        "FiraCode-Bold",
    ]

    static func clamped(_ size: Double) -> Double {
        min(maximumSize, max(minimumSize, size))
    }

    #if os(macOS)
    static func regular(size: Double) -> NSFont {
        font(named: "FiraCode-Regular", size: CGFloat(clamped(size)), fallbackWeight: .regular)
    }

    static func semibold(size: CGFloat) -> NSFont {
        font(named: "FiraCode-SemiBold", size: size, fallbackWeight: .semibold)
    }

    static func emphasis(base font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func font(named name: String, size: CGFloat, fallbackWeight: NSFont.Weight) -> NSFont {
        NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: fallbackWeight)
    }
    #else
    static func regular(size: Double) -> UIFont {
        font(named: "FiraCode-Regular", size: CGFloat(clamped(size)), fallbackWeight: .regular)
    }

    static func semibold(size: CGFloat) -> UIFont {
        font(named: "FiraCode-SemiBold", size: size, fallbackWeight: .semibold)
    }

    static func emphasis(base font: UIFont) -> UIFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) ?? font.fontDescriptor
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func font(named name: String, size: CGFloat, fallbackWeight: UIFont.Weight) -> UIFont {
        UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: fallbackWeight)
    }
    #endif
}

enum TypesetBundledFonts {
    static func register() {
        #if os(macOS)
        _ = registeredFonts
        #endif
    }

    #if os(macOS)
    private static let registeredFonts: Void = {
        for fileName in SourceEditorFont.bundledFontFileNames {
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "ttf") else {
                continue
            }
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    #endif
}

private struct LanguageDocumentationBlock: Identifiable {
    enum Content {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String?, text: String)
        case bullet(String)
    }

    let id: Int
    let content: Content

    static func parse(_ markdown: String) -> [LanguageDocumentationBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [LanguageDocumentationBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInCodeFence = false

        func append(_ content: Content) {
            blocks.append(LanguageDocumentationBlock(id: blocks.count, content: content))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let text = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            paragraphLines.removeAll(keepingCapacity: true)
            if !text.isEmpty {
                append(.paragraph(text))
            }
        }

        func flushCode() {
            let text = codeLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            codeLines.removeAll(keepingCapacity: true)
            if !text.isEmpty {
                append(.code(language: codeLanguage, text: text))
            }
            codeLanguage = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isInCodeFence {
                    flushCode()
                    isInCodeFence = false
                } else {
                    flushParagraph()
                    let language = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    isInCodeFence = true
                }
                continue
            }

            if isInCodeFence {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                append(.heading(level: heading.level, text: heading.text))
            } else if trimmed.hasPrefix("- ") {
                flushParagraph()
                append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                paragraphLines.append(line)
            }
        }

        if isInCodeFence {
            flushCode()
        }
        flushParagraph()
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        for level in stride(from: 3, through: 1, by: -1) {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }
}

private struct SourceEditorLanguageOverlay: View {
    var completions: [TypstCompletionItem]
    var hoverInfo: TypstHoverInfo?
    var cursorDiagnostic: TypstSourceDiagnostic?
    var signatureHelp: TypstSignatureHelp?
    var selectedCompletionIndex: Int
    var fontSize: Double
    var anchor: CGPoint
    var onCompletionSelected: (TypstCompletionItem) -> Void
    var onCompletionDismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = panelSize(constrainedTo: proxy.size)
            let preferredArrowX: CGFloat = 24
            let maxX = max(8, proxy.size.width - size.width - 8)
            let x = min(max(8, anchor.x - preferredArrowX), maxX)
            let preferredY = anchor.y
            let fallbackY = anchor.y - size.height
            let placeBelow = preferredY + size.height <= proxy.size.height - 8
            let y = placeBelow ? preferredY : max(8, fallbackY)
            let arrowX = min(max(18, anchor.x - x), size.width - 18)

            VStack(alignment: .leading, spacing: 8) {
                if !completions.isEmpty {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow) {
                        completionPanel
                    }
                } else if let signatureHelp {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow) {
                        signaturePanel(signatureHelp, contentHeight: size.height - PopoverBubbleShape.arrowHeight)
                    }
                } else if let hoverInfo, !hoverInfo.text.isEmpty {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow) {
                        hoverPanel(
                            hoverInfo.text,
                            diagnostic: cursorDiagnostic,
                            contentHeight: size.height - PopoverBubbleShape.arrowHeight
                        )
                    }
                } else if let cursorDiagnostic {
                    // The cursor is on a diagnostic's line, where the inline badge
                    // would sit behind the caret — show the message here instead.
                    // Tooltips (signature help, hover docs) outrank the error: the
                    // diagnostic stays visible via the line tint and underline.
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow, severity: cursorDiagnostic.severity) {
                        diagnosticPanel(cursorDiagnostic.message)
                    }
                }
            }
            .frame(width: size.width, alignment: .leading)
            .offset(x: x, y: y)
        }
        .allowsHitTesting(!completions.isEmpty || signatureHelp != nil || hoverInfo != nil || cursorDiagnostic != nil)
    }

    private func panelSize(constrainedTo availableSize: CGSize) -> CGSize {
        let availableWidth = max(160, availableSize.width - 16)
        let availableHeight = max(96, availableSize.height - 16)
        if !completions.isEmpty {
            return CGSize(
                width: min(320, availableWidth),
                height: min(CGFloat(min(completions.count, 8)) * 48 + 34, availableHeight)
            )
        } else if signatureHelp != nil {
            return CGSize(width: min(560, availableWidth), height: min(360, availableHeight))
        } else if let hoverInfo, !hoverInfo.text.isEmpty {
            let isReference = hoverInfo.text.count > 240 || hoverInfo.text.contains("\n\n")
            return CGSize(
                width: min(isReference ? 560 : 360, availableWidth),
                height: min(isReference ? 500 : 96, availableHeight)
            )
        } else if let cursorDiagnostic {
            // Size to the whole message so the popover never truncates: width is
            // fixed, height grows to fit the wrapped text.
            let width = min(CGFloat(360), availableWidth)
            let textHeight = diagnosticMessageHeight(cursorDiagnostic.message, width: width - 20)
            return CGSize(
                width: width,
                height: min(textHeight + 16 + PopoverBubbleShape.arrowHeight, availableHeight)
            )
        } else {
            return CGSize(width: min(360, availableWidth), height: min(96, availableHeight))
        }
    }

    /// The inline badge font: two points below the editor font, floored at 9,
    /// medium weight. Shared by the diagnostic popover so it matches the badge.
    private var diagnosticFontSize: CGFloat {
        max(9, CGFloat(fontSize) - 2)
    }

    /// Height of `message` wrapped to `width` in the badge font, so `panelSize`
    /// matches what `diagnosticPanel` renders (and the popover positions right).
    private func diagnosticMessageHeight(_ message: String, width: CGFloat) -> CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: diagnosticFontSize, weight: .medium)
        #else
        let font = UIFont.systemFont(ofSize: diagnosticFontSize, weight: .medium)
        #endif
        let bounds = (message as NSString).boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(bounds.height)
    }

    private var completionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(completions.prefix(8)) { item in
                let index = completions.firstIndex(where: { $0.id == item.id }) ?? 0
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: item.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == selectedCompletionIndex ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .onTapGesture {
                    onCompletionSelected(item)
                }
            }

            Divider()
                .opacity(0.45)

            Text("Dismiss")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCompletionDismiss)
        }
    }

    /// The exact system red/yellow the inline badge fills with, so the popover
    /// matches it.
    private static var systemRed: Color {
        #if os(macOS)
        Color(nsColor: .systemRed)
        #else
        Color(uiColor: .systemRed)
        #endif
    }

    private static var systemYellow: Color {
        #if os(macOS)
        Color(nsColor: .systemYellow)
        #else
        Color(uiColor: .systemYellow)
        #endif
    }

    private func calloutPanel<Content: View>(
        arrowX: CGFloat,
        pointsUp: Bool,
        severity: TypstDiagnosticSeverity? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let bubble = PopoverBubbleShape(pointsUp: pointsUp, arrowX: arrowX)
        let fill: AnyShapeStyle
        let textColor: Color
        let strokeColor: Color
        switch severity {
        case .error:
            fill = AnyShapeStyle(Self.systemRed)
            textColor = .white
            strokeColor = Self.systemRed.opacity(0.6)
        case .warning:
            fill = AnyShapeStyle(Self.systemYellow)
            textColor = .black
            strokeColor = Color.orange.opacity(0.7)
        default:
            fill = AnyShapeStyle(.regularMaterial)
            textColor = .primary
            strokeColor = Color.secondary.opacity(0.18)
        }

        return ZStack(alignment: .topLeading) {
            content()
                .foregroundStyle(textColor)
                .padding(.top, pointsUp ? PopoverBubbleShape.arrowHeight : 0)
                .padding(.bottom, pointsUp ? 0 : PopoverBubbleShape.arrowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            bubble.fill(fill)
        }
        .overlay {
            bubble.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 7)
    }

    private func diagnosticPanel(_ message: String) -> some View {
        // Same size, weight, and colour as the inline badge; no line limit so the
        // full message wraps across as many lines as it needs.
        Text(message)
            .font(.system(size: diagnosticFontSize, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hoverPanel(
        _ text: String,
        diagnostic: TypstSourceDiagnostic?,
        contentHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let diagnostic {
                Text(diagnostic.message)
                    .font(.system(size: diagnosticFontSize, weight: .medium))
                    .foregroundStyle(diagnostic.severity == .error ? .white : .black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(diagnostic.severity == .error ? Self.systemRed : Self.systemYellow)
            }

            ScrollView(.vertical) {
                documentationView(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: max(64, contentHeight))
    }

    private func inlineMarkdownText(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return Text(attributed)
        }
        return Text(markdown)
    }

    private func documentationView(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(LanguageDocumentationBlock.parse(markdown)) { block in
                documentationBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func documentationBlock(_ block: LanguageDocumentationBlock) -> some View {
        switch block.content {
        case .heading(let level, let text):
            inlineMarkdownText(text)
                .font(headingFont(level: level))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 7 : 3)
        case .paragraph(let text):
            inlineMarkdownText(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 5) {
                if let language {
                    Text(language.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                inlineMarkdownText(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .headline
        case 2:
            return .subheadline.weight(.semibold)
        default:
            return .caption.weight(.semibold)
        }
    }

    private func signaturePanel(_ help: TypstSignatureHelp, contentHeight: CGFloat) -> some View {
        let signature = help.signatures[min(max(0, help.activeSignature), max(0, help.signatures.count - 1))]
        let parameter = signature.parameters.indices.contains(help.activeParameter) ? signature.parameters[help.activeParameter] : nil

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                formattedSignature(signature, activeParameter: help.activeParameter)
                    .padding(.bottom, 2)

                if let parameter {
                    Text(parameter.label)
                        .font(.caption.weight(.semibold))
                    if !parameter.documentation.isEmpty {
                        documentationView(parameter.documentation)
                    }
                }

                if !signature.documentation.isEmpty {
                    if parameter != nil {
                        Divider()
                    }
                    documentationView(signature.documentation)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: max(80, contentHeight), alignment: .top)
    }

    @ViewBuilder
    private func formattedSignature(_ signature: TypstSignatureInformation, activeParameter: Int) -> some View {
        if let layout = SignatureDisplayLayout(signature.label) {
            VStack(alignment: .leading, spacing: 3) {
                signatureLine(layout.header)

                ForEach(Array(layout.parameters.enumerated()), id: \.offset) { index, parameter in
                    signatureLine(parameter + (index == layout.parameters.count - 1 ? "" : ","))
                        .foregroundStyle(index == activeParameter ? Color.accentColor : Color.primary)
                        .fontWeight(index == activeParameter ? .semibold : .regular)
                        .padding(.leading, 14)
                }

                signatureLine(layout.footer)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            signatureLine(signature.label)
                .textSelection(.enabled)
        }
    }

    private func signatureLine(_ line: String) -> some View {
        Text(line)
            .font(.system(.callout, design: .monospaced))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "function", "keyword":
            return "function"
        case "file":
            return "doc"
        default:
            return "textformat"
        }
    }
}

/// Breaks an LSP signature into display rows without losing type/default text.
/// Commas nested in calls, arrays, dictionaries, or strings stay with their
/// parameter; only commas at the outer function-argument level create rows.
private struct SignatureDisplayLayout {
    var header: String
    var parameters: [String]
    var footer: String

    init?(_ signature: String) {
        let characters = Array(signature)
        guard let open = characters.firstIndex(of: "(") else { return nil }

        var parameters: [String] = []
        var parameterStart = open + 1
        var parenDepth = 0
        var bracketDepth = 0
        var braceDepth = 0
        var inString = false
        var inRaw = false
        var escaped = false
        var close: Int?

        var index = parameterStart
        while index < characters.count {
            let character = characters[index]

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            if inRaw {
                if character == "`" {
                    inRaw = false
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                inString = true
            case "`":
                inRaw = true
            case "(":
                parenDepth += 1
            case ")":
                if parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 {
                    let parameter = Self.trimmed(characters[parameterStart..<index])
                    if !parameter.isEmpty {
                        parameters.append(parameter)
                    }
                    close = index
                    index = characters.count
                    continue
                }
                parenDepth = max(0, parenDepth - 1)
            case "[":
                bracketDepth += 1
            case "]":
                bracketDepth = max(0, bracketDepth - 1)
            case "{":
                braceDepth += 1
            case "}":
                braceDepth = max(0, braceDepth - 1)
            case "," where parenDepth == 0 && bracketDepth == 0 && braceDepth == 0:
                let parameter = Self.trimmed(characters[parameterStart..<index])
                if !parameter.isEmpty {
                    parameters.append(parameter)
                }
                parameterStart = index + 1
            default:
                break
            }
            index += 1
        }

        guard let close else { return nil }
        self.header = String(characters[...open])
        self.parameters = parameters
        self.footer = String(characters[close...])
    }

    private static func trimmed(_ characters: ArraySlice<Character>) -> String {
        String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// `Shape.path(in:)` can be called off the main actor, so the conformance must be
// nonisolated — this is a pure value type, so that's safe. (Required because the
// project compiles with default MainActor isolation.)
private nonisolated struct PopoverBubbleShape: Shape {
    static let arrowHeight: CGFloat = 9
    private static let arrowWidth: CGFloat = 18
    private static let cornerRadius: CGFloat = 10

    var pointsUp: Bool
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arrowHeight = Self.arrowHeight
        let arrowHalfWidth = Self.arrowWidth / 2
        let radius = min(Self.cornerRadius, rect.width / 2, rect.height / 2)
        let clampedArrowX = min(
            max(radius + arrowHalfWidth, arrowX),
            max(radius + arrowHalfWidth, rect.width - radius - arrowHalfWidth)
        )

        if pointsUp {
            let top = rect.minY + arrowHeight
            let bottom = rect.maxY
            path.move(to: CGPoint(x: rect.minX + radius, y: top))
            path.addLine(to: CGPoint(x: clampedArrowX - arrowHalfWidth, y: top))
            path.addLine(to: CGPoint(x: clampedArrowX, y: rect.minY))
            path.addLine(to: CGPoint(x: clampedArrowX + arrowHalfWidth, y: top))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
        } else {
            let top = rect.minY
            let bottom = rect.maxY - arrowHeight
            path.move(to: CGPoint(x: rect.minX + radius, y: top))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
            path.addLine(to: CGPoint(x: clampedArrowX + arrowHalfWidth, y: bottom))
            path.addLine(to: CGPoint(x: clampedArrowX, y: rect.maxY))
            path.addLine(to: CGPoint(x: clampedArrowX - arrowHalfWidth, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
            path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
        }

        path.closeSubpath()
        return path
    }
}

/// A pending text change produced by an editing engine (comment toggle,
/// bracket pairing): replace `replacementRange` with `replacementText`,
/// then select `selectedRange` (absolute, post-edit).
struct SourceEditorTextEdit {
    var replacementRange: NSRange
    var replacementText: String
    var selectedRange: NSRange

    /// True when the edit changes no text and only moves the caret (typing a
    /// closer that steps over an identical character).
    var isCaretMoveOnly: Bool {
        replacementRange.length == 0 && replacementText.isEmpty
    }
}

/// Shared prose-only autocorrection support. Tinymist supplies the prose ranges;
/// this helper identifies a completed word and keeps the last verified ranges
/// aligned while the next language-service snapshot is in flight.
enum SourceEditorAutocorrection {
    struct Candidate {
        var range: NSRange
        var word: String
    }

    static func candidate(
        forTyping replacement: String,
        in text: String,
        affectedRange: NSRange,
        selectedRange: NSRange,
        proseRanges: [TypstProseRange]
    ) -> Candidate? {
        guard affectedRange == selectedRange,
              selectedRange.length == 0,
              selectedRange.location > 0,
              isCorrectionBoundary(replacement)
        else { return nil }

        let nsText = text as NSString
        guard selectedRange.location <= nsText.length else { return nil }
        var start = selectedRange.location
        while start > 0 {
            let characterRange = nsText.rangeOfComposedCharacterSequence(at: start - 1)
            let character = Character(nsText.substring(with: characterRange))
            guard character.isLetter || character == "'" || character == "’" else { break }
            start = characterRange.location
        }

        let wordRange = NSRange(location: start, length: selectedRange.location - start)
        guard wordRange.length > 0 else { return nil }
        let word = nsText.substring(with: wordRange)
        let characters = Array(word)
        guard characters.count >= 2,
              characters.first?.isLetter == true,
              characters.last?.isLetter == true,
              characters.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" }),
              proseRanges.contains(where: { contains(wordRange, in: $0.range) })
        else { return nil }

        return Candidate(range: wordRange, word: word)
    }

    static func updating(
        _ ranges: [TypstProseRange],
        replacing editRange: NSRange,
        with replacement: String,
        textLength: Int
    ) -> [TypstProseRange] {
        guard editRange.location != NSNotFound else { return [] }
        let replacementLength = (replacement as NSString).length
        let delta = replacementLength - editRange.length
        let editEnd = NSMaxRange(editRange)

        if editRange.length == 0 {
            let continuesProse = isProseContinuation(replacement)
            let containingIndex = ranges.firstIndex {
                let start = $0.range.location
                let end = NSMaxRange($0.range)
                if editRange.location > start && editRange.location < end {
                    return true
                }
                return continuesProse && (editRange.location == start || editRange.location == end)
            }
            return ranges.enumerated().map { index, proseRange in
                var range = proseRange.range
                if index == containingIndex {
                    range.length += replacementLength
                } else if editRange.location <= range.location {
                    range.location += replacementLength
                }
                return TypstProseRange(range: range)
            }
        }

        let containingIndex = ranges.firstIndex {
            editRange.location >= $0.range.location && editEnd <= NSMaxRange($0.range)
        }
        return ranges.enumerated().compactMap { index, proseRange in
            var range = proseRange.range
            if index == containingIndex {
                range.length = max(0, range.length + delta)
                return range.length > 0 ? TypstProseRange(range: range) : nil
            }
            if editEnd <= range.location {
                range.location = max(0, range.location + delta)
                return TypstProseRange(range: range)
            }
            if editRange.location >= NSMaxRange(range) {
                return proseRange
            }
            // An edit crossing a semantic boundary invalidates that range until
            // Tinymist returns the next authoritative snapshot.
            return nil
        }
    }

    static func preservesSemanticClassification(
        replacing range: NSRange,
        with replacement: String,
        in text: String
    ) -> Bool {
        let nsText = text as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= nsText.length else { return false }
        let removed = nsText.substring(with: range)
        return !replacement.contains(where: semanticDelimiters.contains)
            && !removed.contains(where: semanticDelimiters.contains)
    }

    private static func isCorrectionBoundary(_ replacement: String) -> Bool {
        guard replacement.count == 1, let character = replacement.first else { return false }
        return character.isWhitespace || ".,;:!?".contains(character)
    }

    private static func isProseContinuation(_ replacement: String) -> Bool {
        guard !replacement.isEmpty else { return false }
        return replacement.allSatisfy { character in
            character.isLetter || character.isNumber || character.isWhitespace
                || ".,;:!?'-’".contains(character)
        }
    }

    private static let semanticDelimiters: Set<Character> = [
        "#", "$", "\\", "\"", "`", "@", "<", ">", "[", "]", "{", "}", "(", ")", "*", "_", "/", "=",
    ]

    private static func contains(_ inner: NSRange, in outer: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer)
    }
}

enum SourceEditorCommentToggle {
    static func edit(for text: String, selectedRange: NSRange) -> SourceEditorTextEdit? {
        let nsText = text as NSString
        let textLength = nsText.length
        if textLength == 0 {
            return SourceEditorTextEdit(
                replacementRange: NSRange(location: 0, length: 0),
                replacementText: "// ",
                selectedRange: NSRange(location: 3, length: 0)
            )
        }

        let selectedRange = clamped(selectedRange, length: textLength)
        let targetRange: NSRange
        if selectedRange.length > 0 {
            targetRange = selectedLineRange(for: selectedRange, in: nsText)
        } else {
            targetRange = paragraphRange(containing: selectedRange.location, in: nsText)
        }
        guard targetRange.location >= 0, targetRange.length > 0 else { return nil }

        let lineRanges = lineRanges(in: targetRange, text: nsText)
        guard !lineRanges.isEmpty else { return nil }

        let nonBlankLines = lineRanges.filter { !isBlankLine($0, in: nsText) }
        let shouldUncomment = !nonBlankLines.isEmpty && nonBlankLines.allSatisfy { commentRemoval(in: $0, text: nsText) != nil }
        let shouldChangeBlankLines = nonBlankLines.isEmpty
        let originalCursor = selectedRange.location
        var adjustedCursor = originalCursor
        var replacement = ""

        for lineRange in lineRanges {
            let blankLine = isBlankLine(lineRange, in: nsText)
            if blankLine && !shouldChangeBlankLines {
                replacement += nsText.substring(with: lineRange)
                continue
            }

            if shouldUncomment, let removal = commentRemoval(in: lineRange, text: nsText) {
                let line = nsText.substring(with: lineRange) as NSString
                let relativeRemoval = NSRange(location: removal.location - lineRange.location, length: removal.length)
                replacement += line.replacingCharacters(in: relativeRemoval, with: "")
                adjustedCursor = cursor(originalCursor: adjustedCursor, removing: removal)
            } else if !shouldUncomment {
                let insertionLocation = lineRange.location + indentationLength(in: lineRange, text: nsText)
                let line = nsText.substring(with: lineRange) as NSString
                let relativeInsertionLocation = insertionLocation - lineRange.location
                replacement += line.replacingCharacters(
                    in: NSRange(location: relativeInsertionLocation, length: 0),
                    with: "// "
                )
                if insertionLocation <= adjustedCursor {
                    adjustedCursor += 3
                }
            } else {
                replacement += nsText.substring(with: lineRange)
            }
        }

        let replacementLength = (replacement as NSString).length
        let nextSelection: NSRange
        if selectedRange.length > 0 {
            nextSelection = NSRange(location: targetRange.location, length: replacementLength)
        } else {
            nextSelection = NSRange(
                location: min(max(0, adjustedCursor), textLength - targetRange.length + replacementLength),
                length: 0
            )
        }

        return SourceEditorTextEdit(
            replacementRange: targetRange,
            replacementText: replacement,
            selectedRange: nextSelection
        )
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    private static func selectedLineRange(for selectedRange: NSRange, in text: NSString) -> NSRange {
        var effectiveRange = selectedRange
        if selectedRange.length > 0 {
            let end = NSMaxRange(selectedRange)
            if end > selectedRange.location, end <= text.length {
                let previousCharacter = text.character(at: end - 1)
                if previousCharacter == 10 || previousCharacter == 13 {
                    effectiveRange.length -= 1
                }
            }
        }
        return text.lineRange(for: effectiveRange)
    }

    private static func paragraphRange(containing location: Int, in text: NSString) -> NSRange {
        let textLength = text.length
        let lineLocation = min(max(0, location), max(0, textLength - 1))
        let currentLine = text.lineRange(for: NSRange(location: lineLocation, length: 0))
        guard !isBlankLine(currentLine, in: text) else { return currentLine }

        var start = currentLine.location
        while start > 0 {
            let previousLine = text.lineRange(for: NSRange(location: start - 1, length: 0))
            guard previousLine.location < start, !isBlankLine(previousLine, in: text) else { break }
            start = previousLine.location
        }

        var end = NSMaxRange(currentLine)
        while end < textLength {
            let nextLine = text.lineRange(for: NSRange(location: end, length: 0))
            guard NSMaxRange(nextLine) > end, !isBlankLine(nextLine, in: text) else { break }
            end = NSMaxRange(nextLine)
        }

        return NSRange(location: start, length: end - start)
    }

    private static func lineRanges(in targetRange: NSRange, text: NSString) -> [NSRange] {
        let end = NSMaxRange(targetRange)
        var ranges: [NSRange] = []
        var location = targetRange.location
        while location < end {
            let lineRange = text.lineRange(for: NSRange(location: min(location, max(0, text.length - 1)), length: 0))
            guard lineRange.length > 0, NSMaxRange(lineRange) > location else { break }
            ranges.append(lineRange)
            location = NSMaxRange(lineRange)
        }
        return ranges
    }

    private static func isBlankLine(_ lineRange: NSRange, in text: NSString) -> Bool {
        let body = lineBody(in: lineRange, text: text)
        return body.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func commentRemoval(in lineRange: NSRange, text: NSString) -> NSRange? {
        let body = lineBody(in: lineRange, text: text) as NSString
        let indentation = indentationLength(in: lineRange, text: text)
        guard body.length >= indentation + 2 else { return nil }
        guard body.substring(from: indentation).hasPrefix("//") else { return nil }
        let hasFollowingSpace = body.length >= indentation + 3 && body.character(at: indentation + 2) == 32
        return NSRange(location: lineRange.location + indentation, length: hasFollowingSpace ? 3 : 2)
    }

    private static func indentationLength(in lineRange: NSRange, text: NSString) -> Int {
        let body = lineBody(in: lineRange, text: text) as NSString
        var length = 0
        while length < body.length {
            let character = body.character(at: length)
            guard character == 32 || character == 9 else { break }
            length += 1
        }
        return length
    }

    private static func lineBody(in lineRange: NSRange, text: NSString) -> String {
        let line = text.substring(with: lineRange) as NSString
        var bodyLength = line.length
        while bodyLength > 0 {
            let character = line.character(at: bodyLength - 1)
            guard character == 10 || character == 13 else { break }
            bodyLength -= 1
        }
        return line.substring(to: bodyLength)
    }

    private static func cursor(originalCursor: Int, removing range: NSRange) -> Int {
        guard range.location < originalCursor else { return originalCursor }
        return originalCursor - min(range.length, originalCursor - range.location)
    }
}


enum SourceEditorDropSnippet {
    static let defaultImageTemplate = "#image(\"{path}\")"
    static let defaultFigureTemplate = "#figure(\n  {cursor},\n  caption: [],\n)"
    static let defaultTableTemplate = "#table(\n  columns: 2,\n  {cursor},\n)"

    /// Resolves an insertion template against the currently selected text.
    ///
    /// `{cursor}` marks where the selection is dropped in (so an insert can wrap
    /// the current selection) and where the caret lands afterwards. The returned
    /// `selectionLength` covers the re-inserted selection so it stays highlighted
    /// in its new location; for an empty selection the caret is collapsed there.
    /// If the template has no `{cursor}`, the selection is appended at the end.
    static func resolveInsertion(
        _ template: String,
        fallback: String,
        selectedText: String
    ) -> (text: String, selectionLocation: Int, selectionLength: Int) {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : template
        let placeholder = "{cursor}"
        let selectionLength = (selectedText as NSString).length
        if let range = resolved.range(of: placeholder) {
            let location = (String(resolved[..<range.lowerBound]) as NSString).length
            let text = resolved.replacingOccurrences(of: placeholder, with: selectedText)
            return (text, location, selectionLength)
        }
        let location = (resolved as NSString).length
        return (resolved + selectedText, location, selectionLength)
    }

    static func snippet(
        for path: String,
        imagePaths: Set<String>,
        typstPaths: Set<String>,
        imageTemplate: String
    ) -> String? {
        if imagePaths.contains(path) {
            return imageSnippet(for: path, template: imageTemplate)
        }

        if typstPaths.contains(path) {
            return "#include \"\(escapedStringPath(path))\""
        }

        return nil
    }

    static func snippetForKnownPackagePath(_ path: String, imageTemplate: String) -> String? {
        if canCreateImageSnippet(forFileName: path) {
            return imageSnippet(for: path, template: imageTemplate)
        }
        if path.lowercased().hasSuffix(".typ") {
            return "#include \"\(escapedStringPath(path))\""
        }
        return nil
    }

    static func canCreateSnippet(forFileName fileName: String) -> Bool {
        canCreateImageSnippet(forFileName: fileName) || fileName.lowercased().hasSuffix(".typ")
    }

    private static func canCreateImageSnippet(forFileName fileName: String) -> Bool {
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private static func imageSnippet(for path: String, template: String) -> String {
        let cleanTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTemplate = cleanTemplate.isEmpty ? defaultImageTemplate : cleanTemplate
        return resolvedTemplate.replacingOccurrences(of: "{path}", with: escapedStringPath(path))
    }

    private static func escapedStringPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Shared (macOS + iOS) auto-closing for Typst source: typing `(`, `[`, `{`,
/// `$`, or `"` inserts the matching delimiter (or wraps the selection); typing
/// a closer directly before an identical character skips over it; backspacing
/// the opener of an empty pair deletes both halves. Pure text logic — each
/// platform's text-view delegate applies the returned edit.
enum SourceEditorBracketPairing {
    private static let closers: [Character: Character] = ["(": ")", "[": "]", "{": "}", "$": "$", "\"": "\""]
    private static let closingSet: Set<Character> = [")", "]", "}", "$", "\""]
    private static let symmetric: Set<Character> = ["$", "\""]

    /// The edit for typing `typed` at `selectedRange`, or nil to let the text
    /// view handle the keystroke natively.
    static func edit(forTyping typed: String, in text: String, selectedRange: NSRange) -> SourceEditorTextEdit? {
        guard typed.count == 1, let char = typed.first else { return nil }
        let nsText = text as NSString
        guard selectedRange.location >= 0, NSMaxRange(selectedRange) <= nsText.length else { return nil }

        // Wrap a selection in the pair, keeping it selected inside.
        if selectedRange.length > 0, let closer = closers[char] {
            let selected = nsText.substring(with: selectedRange)
            return SourceEditorTextEdit(
                replacementRange: selectedRange,
                replacementText: "\(char)\(selected)\(closer)",
                selectedRange: NSRange(location: selectedRange.location + 1, length: selectedRange.length)
            )
        }
        guard selectedRange.length == 0 else { return nil }
        let caret = selectedRange.location
        let next = character(in: nsText, at: caret)

        // Typing a closer (or symmetric delimiter) directly before an identical
        // character steps over it instead of inserting a duplicate.
        if closingSet.contains(char), next == char {
            return SourceEditorTextEdit(
                replacementRange: NSRange(location: caret, length: 0),
                replacementText: "",
                selectedRange: NSRange(location: caret + 1, length: 0)
            )
        }

        // Auto-close an opener — unless it's gluing onto a word: typing `(`
        // before `word` shouldn't produce `(|)word`, and a quote/dollar right
        // after a word is a manual close, not an opener.
        guard let closer = closers[char] else { return nil }
        if let next, isWordCharacter(next) { return nil }
        if symmetric.contains(char), caret > 0,
           let previous = character(in: nsText, at: caret - 1),
           isWordCharacter(previous) {
            return nil
        }
        return SourceEditorTextEdit(
            replacementRange: NSRange(location: caret, length: 0),
            replacementText: "\(char)\(closer)",
            selectedRange: NSRange(location: caret + 1, length: 0)
        )
    }

    /// The edit for a plain backspace at a caret: deleting the opener of an
    /// empty pair removes both halves. nil = normal single-character delete.
    static func editForBackspace(in text: String, selectedRange: NSRange) -> SourceEditorTextEdit? {
        guard selectedRange.length == 0, selectedRange.location > 0 else { return nil }
        let nsText = text as NSString
        let caret = selectedRange.location
        guard caret < nsText.length,
              let previous = character(in: nsText, at: caret - 1),
              let closer = closers[previous],
              character(in: nsText, at: caret) == closer else { return nil }
        return SourceEditorTextEdit(
            replacementRange: NSRange(location: caret - 1, length: 2),
            replacementText: "",
            selectedRange: NSRange(location: caret - 1, length: 0)
        )
    }

    private static func character(in text: NSString, at index: Int) -> Character? {
        guard index >= 0, index < text.length else { return nil }
        let range = text.rangeOfComposedCharacterSequence(at: index)
        return Character(text.substring(with: range))
    }

    private static func isWordCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber
    }
}

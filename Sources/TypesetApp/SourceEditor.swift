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
    var completions: [TypstCompletionItem] = []
    var hoverInfo: TypstHoverInfo?
    var cursorDiagnostic: TypstSourceDiagnostic?
    var signatureHelp: TypstSignatureHelp?
    var selectedCompletionIndex = 0
    var showLineNumbers = false
    var spellCheckingEnabled = false
    var fixedTopContentInset: CGFloat?
    var onTextChange: (String, NSRange) -> Void = { _, _ in }
    var onSelectionChange: (NSRange) -> Void = { _ in }
    var onCompletionSelected: (TypstCompletionItem) -> Void = { _ in }
    var onCompletionMove: (Int) -> Void = { _ in }
    var onCompletionAccept: () -> Void = {}
    var onCompletionDismiss: () -> Void = {}
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
            showLineNumbers: showLineNumbers,
            spellCheckingEnabled: spellCheckingEnabled,
            fixedTopContentInset: fixedTopContentInset,
            onTextChange: onTextChange,
            onSelectionChange: onSelectionChange,
            isCompletionPresented: !completions.isEmpty,
            onCompletionMove: onCompletionMove,
            onCompletionAccept: onCompletionAccept,
            onCompletionDismiss: onCompletionDismiss,
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
            let size = panelSize
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
                        signaturePanel(signatureHelp)
                    }
                } else if let cursorDiagnostic {
                    // The cursor is on a diagnostic's line, where the inline badge
                    // would sit behind the caret — show the message here instead.
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow, severity: cursorDiagnostic.severity) {
                        diagnosticPanel(cursorDiagnostic.message)
                    }
                } else if let hoverInfo, !hoverInfo.text.isEmpty {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow) {
                        hoverPanel(hoverInfo.text)
                    }
                }
            }
            .frame(width: size.width, alignment: .leading)
            .offset(x: x, y: y)
        }
        .allowsHitTesting(!completions.isEmpty || signatureHelp != nil || hoverInfo != nil)
    }

    private var panelSize: CGSize {
        if !completions.isEmpty {
            return CGSize(width: 320, height: CGFloat(min(completions.count, 8)) * 48 + 34)
        } else if signatureHelp != nil {
            return CGSize(width: 430, height: 108)
        } else if let cursorDiagnostic {
            // Size to the whole message so the popover never truncates: width is
            // fixed, height grows to fit the wrapped text.
            let width: CGFloat = 360
            let textHeight = diagnosticMessageHeight(cursorDiagnostic.message, width: width - 20)
            return CGSize(width: width, height: textHeight + 16 + PopoverBubbleShape.arrowHeight)
        } else {
            return CGSize(width: 360, height: 96)
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

    private func hoverPanel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .textSelection(.enabled)
            .lineLimit(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signaturePanel(_ help: TypstSignatureHelp) -> some View {
        let signature = help.signatures[min(max(0, help.activeSignature), max(0, help.signatures.count - 1))]
        let parameter = signature.parameters.indices.contains(help.activeParameter) ? signature.parameters[help.activeParameter] : nil

        return VStack(alignment: .leading, spacing: 8) {
            highlightedSignature(signature, activeParameter: help.activeParameter)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let parameter {
                VStack(alignment: .leading, spacing: 2) {
                    Text(parameter.label)
                        .font(.caption.weight(.semibold))
                    if !parameter.documentation.isEmpty {
                        Text(parameter.documentation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } else if !signature.documentation.isEmpty {
                Text(signature.documentation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func highlightedSignature(_ signature: TypstSignatureInformation, activeParameter: Int) -> Text {
        guard signature.parameters.indices.contains(activeParameter),
              let range = signature.label.range(of: signature.parameters[activeParameter].label) else {
            return Text(signature.label)
        }

        let before = String(signature.label[..<range.lowerBound])
        let active = String(signature.label[range])
        let after = String(signature.label[range.upperBound...])
        return Text("\(Text(verbatim: before))\(Text(verbatim: active).foregroundStyle(.tint).bold())\(Text(verbatim: after))")
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

private struct PopoverBubbleShape: Shape {
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

struct SourceEditorCommentEdit {
    var replacementRange: NSRange
    var replacementText: String
    var selectedRange: NSRange
}

enum SourceEditorCommentToggle {
    static func edit(for text: String, selectedRange: NSRange) -> SourceEditorCommentEdit? {
        let nsText = text as NSString
        let textLength = nsText.length
        if textLength == 0 {
            return SourceEditorCommentEdit(
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

        return SourceEditorCommentEdit(
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

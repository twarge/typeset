// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TypesetCore
import UniformTypeIdentifiers
import OSLog
import CoreText

private let sourceDropLogger = Logger(subsystem: "com.twarge.typeset", category: "SourceDrop")

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
    var hoverDiagnosticSeverity: TypstDiagnosticSeverity?
    var signatureHelp: TypstSignatureHelp?
    var selectedCompletionIndex = 0
    var showLineNumbers = false
    var spellCheckingEnabled = false
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
                    hoverDiagnosticSeverity: hoverDiagnosticSeverity,
                    signatureHelp: signatureHelp,
                    selectedCompletionIndex: selectedCompletionIndex,
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

private extension CGPoint {
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
    var hoverDiagnosticSeverity: TypstDiagnosticSeverity?
    var signatureHelp: TypstSignatureHelp?
    var selectedCompletionIndex: Int
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
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow, severity: nil) {
                        completionPanel
                    }
                } else if let signatureHelp {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow, severity: nil) {
                        signaturePanel(signatureHelp)
                    }
                } else if let hoverInfo, !hoverInfo.text.isEmpty {
                    calloutPanel(arrowX: arrowX, pointsUp: placeBelow, severity: hoverDiagnosticSeverity) {
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
            CGSize(width: 320, height: CGFloat(min(completions.count, 8)) * 48 + 34)
        } else if signatureHelp != nil {
            CGSize(width: 430, height: 108)
        } else {
            CGSize(width: 360, height: 96)
        }
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

    private func calloutPanel<Content: View>(
        arrowX: CGFloat,
        pointsUp: Bool,
        severity: TypstDiagnosticSeverity?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isError = severity == .error
        let bubble = PopoverBubbleShape(pointsUp: pointsUp, arrowX: arrowX)

        return ZStack(alignment: .topLeading) {
            content()
                .foregroundStyle(isError ? Color.white : Color.primary)
                .padding(.top, pointsUp ? PopoverBubbleShape.arrowHeight : 0)
                .padding(.bottom, pointsUp ? 0 : PopoverBubbleShape.arrowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            if isError {
                bubble.fill(Color.red)
            } else {
                bubble.fill(.regularMaterial)
            }
        }
        .overlay {
            bubble.stroke(isError ? Color.red.opacity(0.55) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(isError ? 0.22 : 0.14), radius: 16, x: 0, y: 7)
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

private struct SourceEditorCommentEdit {
    var replacementRange: NSRange
    var replacementText: String
    var selectedRange: NSRange
}

private enum SourceEditorCommentToggle {
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

#if os(macOS)
import AppKit

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
#else
import UIKit

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

            for diagnostic in diagnostics where diagnostic.range.location < textView.textStorage.length {
                let length = diagnostic.range.length == 0 ? 1 : diagnostic.range.length
                let range = NSRange(location: diagnostic.range.location, length: min(length, textView.textStorage.length - diagnostic.range.location))
                let color: UIColor = diagnostic.severity == .error ? .systemRed : .systemYellow
                textView.textStorage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.thick.rawValue,
                    .underlineColor: color,
                ], range: range)
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
        }

        private func applySafeAreaScrollInsets() {
            let desiredTop = safeAreaInsets.top
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

private enum TypstSyntaxKind {
    case comment
    case string
    case heading
    case command
    case keyword
    case number
    case math
    case label
    case reference
    case emphasis
}

private struct TypstSyntaxToken {
    var kind: TypstSyntaxKind
    var range: NSRange
}

private enum TypstSyntaxHighlighter {
    static let keywords: Set<String> = [
        "as", "auto", "break", "continue", "else", "false", "for", "if", "import", "in",
        "include", "let", "none", "return", "set", "show", "true", "while"
    ]

    static func tokens(in text: String) -> [TypstSyntaxToken] {
        let nsText = text as NSString
        var tokens: [TypstSyntaxToken] = []
        var offset = 0
        var inRawBlock = false

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, enclosingRange, _ in
            let line = nsText.substring(with: lineRange)
            let visibleLine = line.trimmingCharacters(in: .newlines)
            let lineLength = (visibleLine as NSString).length

            if visibleLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                tokens.append(TypstSyntaxToken(kind: .string, range: NSRange(location: offset, length: lineLength)))
                inRawBlock.toggle()
                offset = enclosingRange.upperBound
                return
            }

            if inRawBlock {
                tokens.append(TypstSyntaxToken(kind: .string, range: NSRange(location: offset, length: lineLength)))
                offset = enclosingRange.upperBound
                return
            }

            let trimmed = visibleLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("=") {
                tokens.append(TypstSyntaxToken(kind: .heading, range: NSRange(location: offset, length: lineLength)))
            }

            tokenizeInline(visibleLine, lineOffset: offset, tokens: &tokens)
            offset = enclosingRange.upperBound
        }

        return tokens
    }

    private static func tokenizeInline(_ line: String, lineOffset: Int, tokens: inout [TypstSyntaxToken]) {
        let scalars = Array(line.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "/" && index + 1 < scalars.count && scalars[index + 1] == "/" {
                tokens.append(TypstSyntaxToken(kind: .comment, range: NSRange(location: lineOffset + index, length: scalars.count - index)))
                return
            }

            if scalar == "\"" {
                let end = scanString(scalars, from: index)
                tokens.append(TypstSyntaxToken(kind: .string, range: NSRange(location: lineOffset + index, length: end - index)))
                index = end
                continue
            }

            if scalar == "$" {
                let end = scanUntil(scalars, from: index + 1, delimiter: "$")
                tokens.append(TypstSyntaxToken(kind: .math, range: NSRange(location: lineOffset + index, length: end - index)))
                index = end
                continue
            }

            if scalar == "<" {
                let end = scanUntil(scalars, from: index + 1, delimiter: ">")
                if end <= scalars.count, end > index + 1 {
                    tokens.append(TypstSyntaxToken(kind: .label, range: NSRange(location: lineOffset + index, length: end - index)))
                    index = end
                    continue
                }
            }

            if scalar == "@" {
                let end = scanIdentifierLike(scalars, from: index + 1)
                if end > index + 1 {
                    tokens.append(TypstSyntaxToken(kind: .reference, range: NSRange(location: lineOffset + index, length: end - index)))
                    index = end
                    continue
                }
            }

            if scalar == "#" {
                let end = scanIdentifierLike(scalars, from: index + 1)
                if end > index + 1 {
                    let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                    let kind: TypstSyntaxKind = keywords.contains(name) ? .keyword : .command
                    tokens.append(TypstSyntaxToken(kind: kind, range: NSRange(location: lineOffset + index, length: end - index)))
                    index = end
                    continue
                }
            }

            if scalar == "*" || scalar == "_" {
                let end = scanUntil(scalars, from: index + 1, delimiter: scalar)
                if end <= scalars.count, end > index + 1 {
                    tokens.append(TypstSyntaxToken(kind: .emphasis, range: NSRange(location: lineOffset + index, length: end - index)))
                    index = end
                    continue
                }
            }

            if scalar.properties.numericType != nil {
                let end = scanNumber(scalars, from: index)
                tokens.append(TypstSyntaxToken(kind: .number, range: NSRange(location: lineOffset + index, length: end - index)))
                index = end
                continue
            }

            index += 1
        }
    }

    private static func scanString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 1
        var escaped = false
        while index < scalars.count {
            if escaped {
                escaped = false
            } else if scalars[index] == "\\" {
                escaped = true
            } else if scalars[index] == "\"" {
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    private static func scanUntil(_ scalars: [Unicode.Scalar], from start: Int, delimiter: Unicode.Scalar) -> Int {
        var index = start
        while index < scalars.count {
            if scalars[index] == delimiter {
                return index + 1
            }
            index += 1
        }
        return scalars.count
    }

    private static func scanIdentifierLike(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar == "-" || scalar == "." else {
                break
            }
            index += 1
        }
        return index
    }

    private static func scanNumber(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.properties.numericType != nil || scalar == "." || scalar == "%" || scalar.properties.isAlphabetic else {
                break
            }
            index += 1
        }
        return index
    }
}

#if os(macOS)
private extension TypstSyntaxHighlighter {
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    static func attributedString(for text: String, font: NSFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes(font: font))
        applyTokens(to: attributed, text: text, font: font)
        return attributed
    }

    @MainActor
    static func applyTemporaryTokens(to textView: NSTextView, text: String, font: NSFont) {
        guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttributes([.font: font], forCharacterRange: fullRange)

        for token in tokens(in: text) where NSMaxRange(token.range) <= textStorage.length {
            layoutManager.addTemporaryAttributes(attributes(for: token.kind, font: font), forCharacterRange: token.range)
        }
    }

    @MainActor
    static func applyTemporaryBaseFont(to textView: NSTextView, font: NSFont) {
        guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttributes([.font: font], forCharacterRange: fullRange)
    }

    static func applyTokens(to attributed: NSMutableAttributedString, text: String, font: NSFont) {
        for token in tokens(in: text) where NSMaxRange(token.range) <= attributed.length {
            attributed.addAttributes(attributes(for: token.kind, font: font), range: token.range)
        }
    }

    static func attributes(for kind: TypstSyntaxKind, font: NSFont) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .comment:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .string:
            return [.foregroundColor: NSColor.systemGreen]
        case .heading:
            return [
                .foregroundColor: NSColor.systemIndigo,
                .font: SourceEditorFont.semibold(size: font.pointSize),
            ]
        case .command:
            return [.foregroundColor: NSColor.systemBlue]
        case .keyword:
            return [
                .foregroundColor: NSColor.systemPurple,
                .font: SourceEditorFont.semibold(size: font.pointSize),
            ]
        case .number:
            return [.foregroundColor: NSColor.systemOrange]
        case .math:
            return [.foregroundColor: NSColor.systemPink]
        case .label:
            return [.foregroundColor: NSColor.systemTeal]
        case .reference:
            return [.foregroundColor: NSColor.systemRed]
        case .emphasis:
            return [
                .foregroundColor: NSColor.labelColor,
                .font: SourceEditorFont.emphasis(base: font),
            ]
        }
    }
}
#else
private extension TypstSyntaxHighlighter {
    static func baseAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
    }

    static func attributedString(for text: String, font: UIFont) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes(font: font))
        applyTokens(to: attributed, text: text, font: font)
        return attributed
    }

    @MainActor
    static func applyTemporaryTokens(to textView: UITextView, text: String, font: UIFont) {
        textView.textStorage.beginEditing()
        textView.textStorage.setAttributes(baseAttributes(font: font), range: NSRange(location: 0, length: textView.textStorage.length))
        applyTokens(to: textView.textStorage, text: text, font: font)
        textView.textStorage.endEditing()
    }

    static func applyTokens(to attributed: NSMutableAttributedString, text: String, font: UIFont) {
        for token in tokens(in: text) where NSMaxRange(token.range) <= attributed.length {
            attributed.addAttributes(attributes(for: token.kind, font: font), range: token.range)
        }
    }

    static func attributes(for kind: TypstSyntaxKind, font: UIFont) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .comment:
            return [.foregroundColor: UIColor.secondaryLabel]
        case .string:
            return [.foregroundColor: UIColor.systemGreen]
        case .heading:
            return [
                .foregroundColor: UIColor.systemIndigo,
                .font: SourceEditorFont.semibold(size: font.pointSize),
            ]
        case .command:
            return [.foregroundColor: UIColor.systemBlue]
        case .keyword:
            return [
                .foregroundColor: UIColor.systemPurple,
                .font: SourceEditorFont.semibold(size: font.pointSize),
            ]
        case .number:
            return [.foregroundColor: UIColor.systemOrange]
        case .math:
            return [.foregroundColor: UIColor.systemPink]
        case .label:
            return [.foregroundColor: UIColor.systemTeal]
        case .reference:
            return [.foregroundColor: UIColor.systemRed]
        case .emphasis:
            return [
                .foregroundColor: UIColor.label,
                .font: SourceEditorFont.emphasis(base: font),
            ]
        }
    }
}
#endif

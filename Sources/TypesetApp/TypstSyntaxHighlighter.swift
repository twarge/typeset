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

enum TypstSyntaxKind: Sendable {
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

struct TypstSyntaxToken: Sendable {
    var kind: TypstSyntaxKind
    var range: NSRange
}

/// Which tokenizer colors a file. Packages hold data and generator scripts
/// alongside the Typst sources, and Typst's tokenizer would mis-color them —
/// worse, its notion of "prose" would invite autocorrection into code.
enum SourceSyntax: Equatable, Sendable {
    case typst
    case python
    case plainText

    /// The syntax for a package-relative path. Anything without a tokenizer of
    /// its own (`.csv`, `.json`, …) is left unstyled rather than mis-styled.
    static func forPath(_ path: String) -> SourceSyntax {
        switch (path as NSString).pathExtension.lowercased() {
        case "typ":
            return .typst
        case "py":
            return .python
        default:
            return .plainText
        }
    }
}

enum TypstSyntaxHighlighter {
    nonisolated static let keywords: Set<String> = [
        "as", "auto", "break", "continue", "else", "false", "for", "if", "import", "in",
        "include", "let", "none", "return", "set", "show", "true", "while"
    ]

    /// `checkingCancellation` is for the editor's background pass, which is
    /// superseded on every keystroke: a cancelled pass stops early and returns
    /// tokens its caller is about to discard. Leave it off anywhere the result
    /// is used whatever the surrounding task's state.
    nonisolated static func tokens(
        in text: String,
        syntax: SourceSyntax,
        checkingCancellation: Bool = false
    ) -> [TypstSyntaxToken] {
        switch syntax {
        case .typst:
            return tokens(in: text, checkingCancellation: checkingCancellation)
        case .python:
            return pythonTokens(in: text, checkingCancellation: checkingCancellation)
        case .plainText:
            return []
        }
    }

    /// Tokenizes Python into the shared token kinds, so generator scripts get
    /// the same styling pipeline as Typst sources. Comments and strings win
    /// over everything else; triple-quoted strings span lines.
    nonisolated static func pythonTokens(in text: String, checkingCancellation: Bool = false) -> [TypstSyntaxToken] {
        let scalars = Array(text.unicodeScalars)
        let offsets = Self.utf16Offsets(of: scalars)
        var tokens: [TypstSyntaxToken] = []
        var index = 0

        // The scan below walks Unicode scalars; TextKit ranges are UTF-16.
        func append(_ kind: TypstSyntaxKind, from start: Int, to end: Int) {
            tokens.append(TypstSyntaxToken(
                kind: kind,
                range: NSRange(location: offsets[start], length: offsets[end] - offsets[start])
            ))
        }

        func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        var steps = 0
        while index < scalars.count {
            steps += 1
            if checkingCancellation, steps & 0xFFF == 0, Task.isCancelled { break }
            let scalar = scalars[index]

            if scalar == "#" {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                append(.comment, from: index, to: end)
                index = end
                continue
            }

            if scalar == "\"" || scalar == "'" {
                let quote = scalar
                let isTriple = index + 2 < scalars.count
                    && scalars[index + 1] == quote
                    && scalars[index + 2] == quote
                let delimiterLength = isTriple ? 3 : 1
                var end = index + delimiterLength
                while end < scalars.count {
                    if scalars[end] == "\\" {
                        end += 2
                        continue
                    }
                    if scalars[end] == quote {
                        if !isTriple {
                            end += 1
                            break
                        }
                        if end + 2 < scalars.count, scalars[end + 1] == quote, scalars[end + 2] == quote {
                            end += 3
                            break
                        }
                    }
                    // An unterminated single-quoted string ends at the newline,
                    // so one stray quote can't paint the rest of the file.
                    if !isTriple, scalars[end] == "\n" { break }
                    end += 1
                }
                let clamped = min(end, scalars.count)
                append(.string, from: index, to: clamped)
                index = clamped
                continue
            }

            if CharacterSet.decimalDigits.contains(scalar),
               index == 0 || !isIdentifierScalar(scalars[index - 1]) {
                var end = index
                while end < scalars.count,
                      CharacterSet.alphanumerics.contains(scalars[end]) || scalars[end] == "." || scalars[end] == "_" {
                    end += 1
                }
                append(.number, from: index, to: end)
                index = end
                continue
            }

            if isIdentifierScalar(scalar), !CharacterSet.decimalDigits.contains(scalar) {
                var end = index
                while end < scalars.count, isIdentifierScalar(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[index..<end]))
                if pythonKeywords.contains(word) {
                    append(.keyword, from: index, to: end)
                } else if pythonBuiltins.contains(word) {
                    append(.command, from: index, to: end)
                }
                index = end
                continue
            }

            index += 1
        }

        return tokens
    }

    nonisolated static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
        "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]

    nonisolated static let pythonBuiltins: Set<String> = [
        "abs", "all", "any", "bool", "dict", "enumerate", "filter", "float",
        "format", "int", "len", "list", "map", "max", "min", "print", "range",
        "repr", "reversed", "round", "set", "sorted", "str", "sum", "tuple", "zip",
    ]

    nonisolated static func tokens(in text: String, checkingCancellation: Bool = false) -> [TypstSyntaxToken] {
        let nsText = text as NSString
        var tokens: [TypstSyntaxToken] = []
        var offset = 0
        var inRawBlock = false

        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, enclosingRange, stop in
            if checkingCancellation, Task.isCancelled {
                stop.pointee = true
                return
            }
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

    nonisolated private static func tokenizeInline(_ line: String, lineOffset: Int, tokens: inout [TypstSyntaxToken]) {
        let scalars = Array(line.unicodeScalars)
        let offsets = Self.utf16Offsets(of: scalars)
        var index = 0

        // The scan below walks Unicode scalars; TextKit ranges are UTF-16, and
        // the two part ways after the first character outside the BMP (an
        // emoji, a math alphanumeric), which used to shift every later token
        // on the line.
        func append(_ kind: TypstSyntaxKind, from start: Int, to end: Int) {
            tokens.append(TypstSyntaxToken(
                kind: kind,
                range: NSRange(
                    location: lineOffset + offsets[start],
                    length: offsets[end] - offsets[start]
                )
            ))
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "/" && index + 1 < scalars.count && scalars[index + 1] == "/" {
                append(.comment, from: index, to: scalars.count)
                return
            }

            if scalar == "\"" {
                let end = scanString(scalars, from: index)
                append(.string, from: index, to: end)
                index = end
                continue
            }

            if scalar == "$" {
                // Display math routinely opens on one line and closes on
                // another, and this tokenizer works a line at a time, so an
                // unclosed `$` colors the rest of its line.
                let end = scanUntil(scalars, from: index + 1, delimiter: "$") ?? scalars.count
                append(.math, from: index, to: end)
                index = end
                continue
            }

            // A label is `<name>` on one line. A lone `<` is a comparison, and
            // must not color the rest of the line.
            if scalar == "<", let end = scanLabel(scalars, from: index) {
                append(.label, from: index, to: end)
                index = end
                continue
            }

            if scalar == "@" {
                let end = scanIdentifierLike(scalars, from: index + 1)
                if end > index + 1 {
                    append(.reference, from: index, to: end)
                    index = end
                    continue
                }
            }

            if scalar == "#" {
                let end = scanIdentifierLike(scalars, from: index + 1)
                if end > index + 1 {
                    let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                    append(keywords.contains(name) ? .keyword : .command, from: index, to: end)
                    index = end
                    continue
                }
            }

            // Emphasis needs its closing delimiter on the same line, and — as
            // in Typst itself — a `*` or `_` between two word characters
            // (`my_var`, `2*3`) is not a delimiter at all.
            if scalar == "*" || scalar == "_",
               !isInsideWord(scalars, at: index),
               let end = scanUntil(scalars, from: index + 1, delimiter: scalar),
               end > index + 2 {
                append(.emphasis, from: index, to: end)
                index = end
                continue
            }

            if scalar.properties.numericType != nil {
                let end = scanNumber(scalars, from: index)
                append(.number, from: index, to: end)
                index = end
                continue
            }

            index += 1
        }
    }

    /// `result[i]` is the UTF-16 offset of scalar `i`; the last entry is the
    /// UTF-16 length of the whole run.
    nonisolated private static func utf16Offsets(of scalars: [Unicode.Scalar]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offsets.append(offset)
            offset += scalar.utf16.count
        }
        offsets.append(offset)
        return offsets
    }

    nonisolated private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    nonisolated private static func isInsideWord(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        index > 0 && index + 1 < scalars.count
            && isWordScalar(scalars[index - 1])
            && isWordScalar(scalars[index + 1])
    }

    /// The index just past the `>` closing a label that opens at `start`, or
    /// `nil` when what follows the `<` is not a label.
    nonisolated private static func scanLabel(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ">" {
                return index > start + 1 ? index + 1 : nil
            }
            guard isWordScalar(scalar) || scalar == "_" || scalar == "-" || scalar == "." || scalar == ":" else {
                return nil
            }
            index += 1
        }
        return nil
    }

    nonisolated private static func scanString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
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

    /// The index just past the next `delimiter`, or `nil` when the rest of the
    /// line has none — callers decide whether an unterminated run is styled.
    nonisolated private static func scanUntil(_ scalars: [Unicode.Scalar], from start: Int, delimiter: Unicode.Scalar) -> Int? {
        var index = start
        while index < scalars.count {
            if scalars[index] == delimiter {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    nonisolated private static func scanIdentifierLike(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
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

    nonisolated private static func scanNumber(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
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
extension TypstSyntaxHighlighter {
    static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    static func attributedString(for text: String, font: NSFont, syntax: SourceSyntax) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes(font: font))
        applyTokens(to: attributed, text: text, font: font, syntax: syntax)
        return attributed
    }

    // The macOS editor deliberately runs TextKit 1 (TextKit 2's NSTextView has
    // architecturally unstable height estimation/scrolling — see the parked
    // "macOS editor TextKit 2 migration" stash), so token styling uses
    // NSLayoutManager temporary attributes: display-only, no storage churn.
    @MainActor
    static func applyTemporaryTokens(to textView: NSTextView, text: String, font: NSFont, syntax: SourceSyntax) {
        applyTemporaryTokens(
            to: textView,
            tokens: tokens(in: text, syntax: syntax),
            font: font
        )
    }

    /// Applies tokens that may have been computed away from the main actor.
    /// TextKit mutation still belongs to the main actor, but lexical analysis
    /// does not need to hold up keyboard event processing.
    @MainActor
    static func applyTemporaryTokens(to textView: NSTextView, tokens: [TypstSyntaxToken], font: NSFont) {
        guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttributes([.font: font], forCharacterRange: fullRange)

        for token in tokens where NSMaxRange(token.range) <= textStorage.length {
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

    static func applyTokens(to attributed: NSMutableAttributedString, text: String, font: NSFont, syntax: SourceSyntax) {
        for token in tokens(in: text, syntax: syntax) where NSMaxRange(token.range) <= attributed.length {
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
extension TypstSyntaxHighlighter {
    static func baseAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
    }

    static func attributedString(for text: String, font: UIFont, syntax: SourceSyntax) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes(font: font))
        applyTokens(to: attributed, text: text, font: font, syntax: syntax)
        return attributed
    }

    @MainActor
    static func applyTokenStyling(to textView: UITextView, text: String, font: UIFont, syntax: SourceSyntax) {
        applyTokenStyling(
            to: textView,
            tokens: tokens(in: text, syntax: syntax),
            font: font
        )
    }

    /// Applies tokens that may have been computed away from the main actor.
    @MainActor
    static func applyTokenStyling(to textView: UITextView, tokens: [TypstSyntaxToken], font: UIFont) {
        textView.textStorage.beginEditing()
        textView.textStorage.setAttributes(baseAttributes(font: font), range: NSRange(location: 0, length: textView.textStorage.length))
        for token in tokens where NSMaxRange(token.range) <= textView.textStorage.length {
            textView.textStorage.addAttributes(attributes(for: token.kind, font: font), range: token.range)
        }
        textView.textStorage.endEditing()
    }

    static func applyTokens(to attributed: NSMutableAttributedString, text: String, font: UIFont, syntax: SourceSyntax) {
        for token in tokens(in: text, syntax: syntax) where NSMaxRange(token.range) <= attributed.length {
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

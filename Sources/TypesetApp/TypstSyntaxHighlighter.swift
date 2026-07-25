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

enum TypstSyntaxKind {
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

struct TypstSyntaxToken {
    var kind: TypstSyntaxKind
    var range: NSRange
}

/// Which tokenizer colors a file. Packages hold data and generator scripts
/// alongside the Typst sources, and Typst's tokenizer would mis-color them —
/// worse, its notion of "prose" would invite autocorrection into code.
enum SourceSyntax {
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
    static let keywords: Set<String> = [
        "as", "auto", "break", "continue", "else", "false", "for", "if", "import", "in",
        "include", "let", "none", "return", "set", "show", "true", "while"
    ]

    static func tokens(in text: String, syntax: SourceSyntax) -> [TypstSyntaxToken] {
        switch syntax {
        case .typst:
            return tokens(in: text)
        case .python:
            return pythonTokens(in: text)
        case .plainText:
            return []
        }
    }

    /// Tokenizes Python into the shared token kinds, so generator scripts get
    /// the same styling pipeline as Typst sources. Comments and strings win
    /// over everything else; triple-quoted strings span lines.
    static func pythonTokens(in text: String) -> [TypstSyntaxToken] {
        let scalars = Array(text.unicodeScalars)
        var tokens: [TypstSyntaxToken] = []
        var index = 0

        func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if scalar == "#" {
                var end = index
                while end < scalars.count, scalars[end] != "\n" { end += 1 }
                tokens.append(TypstSyntaxToken(kind: .comment, range: NSRange(location: index, length: end - index)))
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
                tokens.append(TypstSyntaxToken(kind: .string, range: NSRange(location: index, length: clamped - index)))
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
                tokens.append(TypstSyntaxToken(kind: .number, range: NSRange(location: index, length: end - index)))
                index = end
                continue
            }

            if isIdentifierScalar(scalar), !CharacterSet.decimalDigits.contains(scalar) {
                var end = index
                while end < scalars.count, isIdentifierScalar(scalars[end]) { end += 1 }
                let word = String(String.UnicodeScalarView(scalars[index..<end]))
                if pythonKeywords.contains(word) {
                    tokens.append(TypstSyntaxToken(kind: .keyword, range: NSRange(location: index, length: end - index)))
                } else if pythonBuiltins.contains(word) {
                    tokens.append(TypstSyntaxToken(kind: .command, range: NSRange(location: index, length: end - index)))
                }
                index = end
                continue
            }

            index += 1
        }

        return tokens
    }

    static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await", "break",
        "class", "continue", "def", "del", "elif", "else", "except", "finally",
        "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal",
        "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
    ]

    static let pythonBuiltins: Set<String> = [
        "abs", "all", "any", "bool", "dict", "enumerate", "filter", "float",
        "format", "int", "len", "list", "map", "max", "min", "print", "range",
        "repr", "reversed", "round", "set", "sorted", "str", "sum", "tuple", "zip",
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
        guard let layoutManager = textView.layoutManager, let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.addTemporaryAttributes([.font: font], forCharacterRange: fullRange)

        for token in tokens(in: text, syntax: syntax) where NSMaxRange(token.range) <= textStorage.length {
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
        textView.textStorage.beginEditing()
        textView.textStorage.setAttributes(baseAttributes(font: font), range: NSRange(location: 0, length: textView.textStorage.length))
        applyTokens(to: textView.textStorage, text: text, font: font, syntax: syntax)
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

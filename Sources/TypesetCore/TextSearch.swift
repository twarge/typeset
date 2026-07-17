// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct TextSearchOptions: Equatable, Sendable {
    public var query: String
    public var isCaseSensitive: Bool
    public var isWholeWord: Bool
    public var usesRegularExpression: Bool

    public init(
        query: String,
        isCaseSensitive: Bool = false,
        isWholeWord: Bool = false,
        usesRegularExpression: Bool = false
    ) {
        self.query = query
        self.isCaseSensitive = isCaseSensitive
        self.isWholeWord = isWholeWord
        self.usesRegularExpression = usesRegularExpression
    }
}

public struct TextSearchOccurrence: Equatable, Sendable {
    public var range: NSRange
    public var replacementText: String?

    public init(range: NSRange, replacementText: String? = nil) {
        self.range = range
        self.replacementText = replacementText
    }
}

public struct TextSearchResult: Equatable, Sendable {
    public var occurrences: [TextSearchOccurrence]
    public var isTruncated: Bool

    public init(occurrences: [TextSearchOccurrence], isTruncated: Bool) {
        self.occurrences = occurrences
        self.isTruncated = isTruncated
    }
}

public struct TextSearchPatternError: LocalizedError, Equatable, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// A compiled search pattern shared by current-file and package-wide search.
/// Ranges use Foundation's UTF-16 convention so they can be handed directly to
/// NSTextView and UITextView.
public struct TextSearchPattern {
    public let options: TextSearchOptions
    private let expression: NSRegularExpression

    public init(options: TextSearchOptions) throws {
        self.options = options

        let queryPattern = options.usesRegularExpression
            ? options.query
            : NSRegularExpression.escapedPattern(for: options.query)
        let pattern: String
        if options.query.isEmpty {
            pattern = "(?!)"
        } else if options.isWholeWord {
            let wordCharacters = "\\p{L}\\p{M}\\p{N}_"
            pattern = "(?<![\(wordCharacters)])(?:\(queryPattern))(?![\(wordCharacters)])"
        } else {
            pattern = queryPattern
        }

        var expressionOptions: NSRegularExpression.Options = []
        if !options.isCaseSensitive {
            expressionOptions.insert(.caseInsensitive)
        }

        do {
            expression = try NSRegularExpression(pattern: pattern, options: expressionOptions)
        } catch {
            throw TextSearchPatternError(message: "Invalid regular expression: \(error.localizedDescription)")
        }
    }

    public func occurrences(
        in text: String,
        replacementTemplate: String? = nil,
        limit: Int? = nil
    ) -> TextSearchResult {
        guard !options.query.isEmpty else {
            return TextSearchResult(occurrences: [], isTruncated: false)
        }

        let searchRange = NSRange(location: 0, length: (text as NSString).length)
        let maximum = limit.map { max(0, $0) }
        var occurrences: [TextSearchOccurrence] = []
        var isTruncated = false

        expression.enumerateMatches(in: text, range: searchRange) { result, _, stop in
            guard let result else { return }
            if let maximum, occurrences.count >= maximum {
                isTruncated = true
                stop.pointee = true
                return
            }

            let replacementText = replacementTemplate.map { template in
                options.usesRegularExpression
                    ? expression.replacementString(for: result, in: text, offset: 0, template: template)
                    : template
            }
            occurrences.append(TextSearchOccurrence(range: result.range, replacementText: replacementText))
        }

        return TextSearchResult(occurrences: occurrences, isTruncated: isTruncated)
    }

    /// Resolves a replacement only when `range` is still an exact match. This
    /// lets a stale sidebar result fail closed after the source has changed.
    public func replacement(
        for range: NSRange,
        in text: String,
        template: String
    ) -> String? {
        guard range.location >= 0, NSMaxRange(range) <= (text as NSString).length else { return nil }
        let matches = occurrences(in: text, replacementTemplate: template).occurrences
        return matches.first(where: { NSEqualRanges($0.range, range) })?.replacementText
    }

    public func replacingAll(in text: String, with template: String) -> String {
        let matches = occurrences(in: text, replacementTemplate: template).occurrences
        guard !matches.isEmpty else { return text }

        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            output.replaceCharacters(in: match.range, with: match.replacementText ?? template)
        }
        return output as String
    }
}

/// Include/exclude filtering for package search. Patterns are comma-, semicolon-
/// or newline-separated globs. `*` stays within one path component, `**` crosses
/// folders, and a pattern without a slash matches any basename.
public struct TextSearchFileFilter {
    private let includeExpressions: [NSRegularExpression]
    private let excludeExpressions: [NSRegularExpression]

    public init(including includePatterns: String = "", excluding excludePatterns: String = "") {
        includeExpressions = Self.expressions(from: includePatterns)
        excludeExpressions = Self.expressions(from: excludePatterns)
    }

    public func includes(path: String) -> Bool {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let fullRange = NSRange(location: 0, length: (normalizedPath as NSString).length)
        let isIncluded = includeExpressions.isEmpty || includeExpressions.contains {
            $0.firstMatch(in: normalizedPath, range: fullRange) != nil
        }
        guard isIncluded else { return false }
        return !excludeExpressions.contains {
            $0.firstMatch(in: normalizedPath, range: fullRange) != nil
        }
    }

    private static func expressions(from value: String) -> [NSRegularExpression] {
        let separators = CharacterSet(charactersIn: ",;\n")
        return value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { try? NSRegularExpression(pattern: globExpression(for: $0), options: [.caseInsensitive]) }
    }

    private static func globExpression(for rawPattern: String) -> String {
        var pattern = rawPattern.replacingOccurrences(of: "\\", with: "/")
        while pattern.hasPrefix("/") { pattern.removeFirst() }

        let matchesBasename = !pattern.contains("/")
        let characters = Array(pattern)
        var body = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        body += "(?:.*/)?"
                        index += 3
                    } else {
                        body += ".*"
                        index += 2
                    }
                } else {
                    body += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                body += "[^/]"
                index += 1
            } else {
                if ".+()[]{}^$|\\".contains(character) {
                    body.append("\\")
                }
                body.append(character)
                index += 1
            }
        }

        if pattern.hasSuffix("/") {
            body += ".*"
        }
        return matchesBasename ? "(?:^|.*/)\(body)$" : "^\(body)$"
    }
}

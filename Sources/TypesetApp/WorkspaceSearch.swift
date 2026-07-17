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

// MARK: - Find in Files

/// One occurrence of the search query in a file, with the surrounding line text
/// split around the match for inline highlighting.
struct FileSearchMatch: Identifiable, Equatable {
    let id: Int            // the match's UTF-16 location (stable within a file)
    let range: NSRange     // the match's range within the file's text
    let lineNumber: Int    // 1-based
    let linePrefix: String
    let matchText: String
    let lineSuffix: String
    let replacementText: String
}

/// All matches within a single file.
struct FileSearchResult: Identifiable, Equatable {
    let id: String         // file path
    let path: String
    let name: String
    let matches: [FileSearchMatch]
    /// True when the file had more matches than `maxMatchesPerFile`, so the
    /// listed matches are only the first page. (Replace All still replaces every
    /// occurrence — see `matchSummary`, which shows "N+".)
    let isTruncated: Bool
}

struct WorkspaceSearchConfiguration: Equatable {
    var options: TextSearchOptions
    var includedFiles: String
    var excludedFiles: String
}

struct FileSearchOutcome: Equatable {
    var results: [FileSearchResult]
    var errorMessage: String?
}

enum FileTextSearch {
    /// Bounds work per file so an enormous accidental match set (e.g. searching a
    /// single space) can't stall the UI.
    static let maxMatchesPerFile = 1000

    static func results(
        in files: [PackageFile],
        configuration: WorkspaceSearchConfiguration,
        replacement: String
    ) -> FileSearchOutcome {
        guard !configuration.options.query.isEmpty else {
            return FileSearchOutcome(results: [], errorMessage: nil)
        }

        let pattern: TextSearchPattern
        do {
            pattern = try TextSearchPattern(options: configuration.options)
        } catch {
            return FileSearchOutcome(results: [], errorMessage: error.localizedDescription)
        }

        let fileFilter = TextSearchFileFilter(
            including: configuration.includedFiles,
            excluding: configuration.excludedFiles
        )
        var output: [FileSearchResult] = []
        for file in files where file.isTextEditable && fileFilter.includes(path: file.path) {
            let nsText = String(decoding: file.data, as: UTF8.self) as NSString
            guard nsText.length > 0 else { continue }
            var matches: [FileSearchMatch] = []
            var lineNumber = 1
            var scannedForLines = 0
            let search = pattern.occurrences(
                in: nsText as String,
                replacementTemplate: replacement,
                limit: maxMatchesPerFile
            )
            for occurrence in search.occurrences {
                let found = occurrence.range
                if found.location > scannedForLines {
                    lineNumber += newlineCount(in: nsText, from: scannedForLines, to: found.location)
                    scannedForLines = found.location
                }
                let lineRange = nsText.lineRange(for: NSRange(location: found.location, length: 0))
                let prefix = nsText.substring(with: NSRange(location: lineRange.location, length: found.location - lineRange.location))
                let suffixStart = NSMaxRange(found)
                let suffixLength = max(0, NSMaxRange(lineRange) - suffixStart)
                let suffix = nsText.substring(with: NSRange(location: suffixStart, length: suffixLength))
                matches.append(FileSearchMatch(
                    id: found.location,
                    range: found,
                    lineNumber: lineNumber,
                    linePrefix: displaySnippet(prefix, keepingTail: true),
                    matchText: nsText.substring(with: found),
                    lineSuffix: displaySnippet(suffix, keepingTail: false),
                    replacementText: occurrence.replacementText ?? replacement
                ))
            }
            if !matches.isEmpty {
                output.append(FileSearchResult(
                    id: file.path,
                    path: file.path,
                    name: file.name,
                    matches: matches,
                    isTruncated: search.isTruncated
                ))
            }
        }
        return FileSearchOutcome(results: output, errorMessage: nil)
    }

    private static func newlineCount(in text: NSString, from start: Int, to end: Int) -> Int {
        var count = 0
        var index = start
        while index < end {
            let r = text.range(of: "\n", options: [], range: NSRange(location: index, length: end - index))
            if r.location == NSNotFound { break }
            count += 1
            index = r.location + 1
        }
        return count
    }

    /// Trims a line fragment to a compact single line, clipping the end away from
    /// the match and collapsing indentation/tabs so the match stays visible.
    private static func displaySnippet(_ raw: String, keepingTail: Bool) -> String {
        var collapsed = raw
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if keepingTail {
            while collapsed.first == " " { collapsed.removeFirst() }
        }
        let limit = 80
        guard collapsed.count > limit else { return collapsed }
        return keepingTail ? "…" + String(collapsed.suffix(limit)) : String(collapsed.prefix(limit)) + "…"
    }
}

/// The Find-in-Files sidebar tab: searches every text file, lists matches
/// grouped by file, and supports replacing a single match or all of them.
struct WorkspaceSearchView: View {
    var files: [PackageFile]
    @Binding var query: String
    @Binding var replacement: String
    @Binding var isCaseSensitive: Bool
    @Binding var isWholeWord: Bool
    @Binding var usesRegularExpression: Bool
    @Binding var includedFiles: String
    @Binding var excludedFiles: String
    @Binding var areFileFiltersVisible: Bool
    @Binding var isReplaceVisible: Bool
    /// One-shot: when true, focus the search field and reset it. Set by ⌘⇧F.
    @Binding var activation: Bool
    var history: [String]
    var onCommitQuery: (String) -> Void
    var onClearHistory: () -> Void
    var onSelectMatch: (String, NSRange) -> Void
    var onReplaceMatch: (String, NSRange, String, WorkspaceSearchConfiguration) -> Void
    var onReplaceAll: (String, WorkspaceSearchConfiguration) -> Void

    @FocusState private var isQueryFocused: Bool

    var body: some View {
        // Compute the search exactly once per body evaluation and thread it
        // through; recomputing inside several computed properties ran the whole
        // multi-file scan 4-5x per keystroke.
        let configuration = WorkspaceSearchConfiguration(
            options: TextSearchOptions(
                query: query,
                isCaseSensitive: isCaseSensitive,
                isWholeWord: isWholeWord,
                usesRegularExpression: usesRegularExpression
            ),
            includedFiles: includedFiles,
            excludedFiles: excludedFiles
        )
        let outcome = FileTextSearch.results(
            in: files,
            configuration: configuration,
            replacement: replacement
        )
        let totalMatches = outcome.results.reduce(0) { $0 + $1.matches.count }
        return VStack(spacing: 0) {
            controls(
                totalMatches: totalMatches,
                configuration: configuration,
                canReplace: outcome.errorMessage == nil
            )
            Divider()
            content(outcome: outcome, totalMatches: totalMatches, configuration: configuration)
        }
        .onAppear { consumeActivationIfNeeded() }
        .onChange(of: activation) { _, _ in consumeActivationIfNeeded() }
    }

    /// Focuses the field only when the user explicitly invoked Find (⌘⇧F), then
    /// clears the flag — so restoring the Find tab on launch never steals focus
    /// from the editor.
    private func consumeActivationIfNeeded() {
        guard activation else { return }
        DispatchQueue.main.async {
            isQueryFocused = true
            activation = false
        }
    }

    private func controls(
        totalMatches: Int,
        configuration: WorkspaceSearchConfiguration,
        canReplace: Bool
    ) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find in files", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isQueryFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    #endif
                    .onSubmit {
                        onCommitQuery(query)
                        isQueryFocused = true
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if !history.isEmpty {
                    Menu {
                        ForEach(history, id: \.self) { previousQuery in
                            Button(previousQuery) {
                                query = previousQuery
                                onCommitQuery(previousQuery)
                                isQueryFocused = true
                            }
                        }
                        Divider()
                        Button("Clear Search History", role: .destructive) {
                            onClearHistory()
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Recent Searches")
                }
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.15)) { isReplaceVisible.toggle() }
                } label: {
                    Image(systemName: isReplaceVisible ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Toggle Replace")

                searchOptionButton("Aa", isActive: isCaseSensitive, help: "Match Case") {
                    isCaseSensitive.toggle()
                }

                searchOptionButton("ab", isActive: isWholeWord, help: "Match Whole Word") {
                    isWholeWord.toggle()
                }

                searchOptionButton(".*", isActive: usesRegularExpression, help: "Use Regular Expression") {
                    usesRegularExpression.toggle()
                }

                Button {
                    withAnimation(.snappy(duration: 0.15)) { areFileFiltersVisible.toggle() }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(areFileFiltersVisible || !includedFiles.isEmpty || !excludedFiles.isEmpty ? Color.accentColor : Color.secondary)
                .help("Filter Files")

                Spacer(minLength: 0)
            }

            if areFileFiltersVisible {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Files to include", text: $includedFiles)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                HStack(spacing: 6) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                    TextField("Files to exclude", text: $excludedFiles)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }

            if isReplaceVisible {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                    TextField("Replace", text: $replacement)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Button("All") {
                        onCommitQuery(query)
                        onReplaceAll(replacement, configuration)
                    }
                    .disabled(query.isEmpty || totalMatches == 0 || !canReplace)
                    .help("Replace every match")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func searchOptionButton(
        _ title: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func content(
        outcome: FileSearchOutcome,
        totalMatches: Int,
        configuration: WorkspaceSearchConfiguration
    ) -> some View {
        if query.isEmpty {
            emptyState(title: "Find in Files", message: "Search the text of every file in this document.", systemImage: "magnifyingglass")
        } else if let errorMessage = outcome.errorMessage {
            emptyState(title: "Invalid Pattern", message: errorMessage, systemImage: "exclamationmark.triangle")
        } else if outcome.results.isEmpty {
            emptyState(title: "No Matches", message: "No file contains the search text.", systemImage: "magnifyingglass")
        } else {
            List {
                Text(matchSummary(results: outcome.results, totalMatches: totalMatches))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(outcome.results) { result in
                    Section(result.path) {
                        ForEach(result.matches) { match in
                            matchRow(result: result, match: match, configuration: configuration)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private func matchSummary(results: [FileSearchResult], totalMatches: Int) -> String {
        let truncated = results.contains { $0.isTruncated }
        let count = truncated ? "\(totalMatches)+" : "\(totalMatches)"
        let fileWord = results.count == 1 ? "file" : "files"
        let matchWord = totalMatches == 1 ? "match" : "matches"
        return "\(count) \(matchWord) in \(results.count) \(fileWord)"
    }

    private func matchRow(
        result: FileSearchResult,
        match: FileSearchMatch,
        configuration: WorkspaceSearchConfiguration
    ) -> some View {
        Button {
            onCommitQuery(query)
            onSelectMatch(result.path, match.range)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text("\(match.lineNumber)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    previewLine(
                        symbol: isReplaceVisible ? "minus" : nil,
                        prefix: match.linePrefix,
                        changedText: match.matchText,
                        suffix: match.lineSuffix,
                        changeColor: isReplaceVisible ? .red : .primary
                    )
                    if isReplaceVisible {
                        previewLine(
                            symbol: "plus",
                            prefix: match.linePrefix,
                            changedText: match.replacementText,
                            suffix: match.lineSuffix,
                            changeColor: .green
                        )
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal") {
                onSelectMatch(result.path, match.range)
            }
            Button("Replace") {
                onCommitQuery(query)
                onReplaceMatch(result.path, match.range, replacement, configuration)
            }
        }
    }

    private func previewLine(
        symbol: String?,
        prefix: String,
        changedText: String,
        suffix: String,
        changeColor: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(changeColor)
                    .frame(width: 10)
            }
            let linePrefix = Text(prefix).foregroundColor(.secondary)
            let displayedChange = changedText.isEmpty ? "∅" : changedText
            let highlightedChange = Text(displayedChange).foregroundColor(changeColor).bold()
            let lineSuffix = Text(suffix).foregroundColor(.secondary)
            Text("\(linePrefix)\(highlightedChange)\(lineSuffix)")
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private func emptyState(title: String, message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .imageScale(.large)
                .foregroundStyle(.tertiary)
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

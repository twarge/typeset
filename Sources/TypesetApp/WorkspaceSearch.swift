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

enum FileTextSearch {
    /// Bounds work per file so an enormous accidental match set (e.g. searching a
    /// single space) can't stall the UI.
    static let maxMatchesPerFile = 1000

    static func results(in files: [PackageFile], query: String, isCaseSensitive: Bool) -> [FileSearchResult] {
        guard !query.isEmpty else { return [] }
        let options: NSString.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var output: [FileSearchResult] = []
        for file in files where file.isTextEditable {
            let nsText = String(decoding: file.data, as: UTF8.self) as NSString
            guard nsText.length > 0 else { continue }
            var matches: [FileSearchMatch] = []
            var isTruncated = false
            var searchStart = 0
            var lineNumber = 1
            var scannedForLines = 0
            while searchStart < nsText.length {
                let found = nsText.range(
                    of: query,
                    options: options,
                    range: NSRange(location: searchStart, length: nsText.length - searchStart)
                )
                if found.location == NSNotFound { break }
                // Cap reached and yet another match exists -> genuinely truncated.
                if matches.count >= maxMatchesPerFile { isTruncated = true; break }
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
                    lineSuffix: displaySnippet(suffix, keepingTail: false)
                ))
                searchStart = found.location + max(1, found.length)
            }
            if !matches.isEmpty {
                output.append(FileSearchResult(id: file.path, path: file.path, name: file.name, matches: matches, isTruncated: isTruncated))
            }
        }
        return output
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
    @Binding var isReplaceVisible: Bool
    /// One-shot: when true, focus the search field and reset it. Set by ⌘⇧F.
    @Binding var activation: Bool
    var onSelectMatch: (String, NSRange) -> Void
    var onReplaceMatch: (String, NSRange, String, String, Bool) -> Void
    var onReplaceAll: (String, String, Bool) -> Void

    @FocusState private var isQueryFocused: Bool

    var body: some View {
        // Compute the search exactly once per body evaluation and thread it
        // through; recomputing inside several computed properties ran the whole
        // multi-file scan 4-5x per keystroke.
        let results = FileTextSearch.results(in: files, query: query, isCaseSensitive: isCaseSensitive)
        let totalMatches = results.reduce(0) { $0 + $1.matches.count }
        return VStack(spacing: 0) {
            controls(totalMatches: totalMatches)
            Divider()
            content(results: results, totalMatches: totalMatches)
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

    private func controls(totalMatches: Int) -> some View {
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
                    #endif
                    .onSubmit { isQueryFocused = true }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button { isCaseSensitive.toggle() } label: {
                    Text("Aa").fontWeight(.semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isCaseSensitive ? Color.accentColor : Color.secondary)
                .help("Match case")

                Button {
                    withAnimation(.snappy(duration: 0.15)) { isReplaceVisible.toggle() }
                } label: {
                    Image(systemName: isReplaceVisible ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Toggle replace")
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
                        onReplaceAll(query, replacement, isCaseSensitive)
                    }
                    .disabled(query.isEmpty || totalMatches == 0)
                    .help("Replace every match")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(results: [FileSearchResult], totalMatches: Int) -> some View {
        if query.isEmpty {
            emptyState(title: "Find in Files", message: "Search the text of every file in this document.", systemImage: "magnifyingglass")
        } else if results.isEmpty {
            emptyState(title: "No Matches", message: "No file contains the search text.", systemImage: "magnifyingglass")
        } else {
            List {
                Text(matchSummary(results: results, totalMatches: totalMatches))
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                ForEach(results) { result in
                    Section(result.name) {
                        ForEach(result.matches) { match in
                            matchRow(result: result, match: match)
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

    private func matchRow(result: FileSearchResult, match: FileSearchMatch) -> some View {
        Button {
            onSelectMatch(result.path, match.range)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(match.lineNumber)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 24, alignment: .trailing)
                let linePrefix = Text(match.linePrefix).foregroundColor(.secondary)
                let highlightedMatch = Text(match.matchText).foregroundColor(.primary).bold()
                let lineSuffix = Text(match.lineSuffix).foregroundColor(.secondary)
                Text("\(linePrefix)\(highlightedMatch)\(lineSuffix)")
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                onReplaceMatch(result.path, match.range, replacement, query, isCaseSensitive)
            }
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


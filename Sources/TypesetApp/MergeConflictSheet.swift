// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TypesetCore

/// Per-hunk resolution for an external-change conflict: non-overlapping
/// changes merged automatically, with a mine/theirs choice for each
/// genuinely overlapping region.
struct MergeConflictSheet: View {
    let conflict: DiskConflict
    let onResolve: ([Int: MergeSide]) -> Void
    let onCancel: () -> Void

    @State private var choices: [Int: MergeSide] = [:]

    private var hunks: [MergeConflict] {
        conflict.mergeResult?.conflicts ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(conflict.fileName)” was changed here and on disk")
                .font(.headline)
            Text("Changes on different lines were merged automatically. Choose a version for each overlapping change:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(hunks) { hunk in
                        hunkRow(hunk)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Merge") { onResolve(choices) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 320, idealHeight: 460)
    }

    @ViewBuilder
    private func hunkRow(_ hunk: MergeConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: choiceBinding(for: hunk.id)) {
                Text("Mine").tag(MergeSide.mine)
                Text("Theirs").tag(MergeSide.theirs)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)

            HStack(alignment: .top, spacing: 8) {
                hunkText(hunk.mineText, label: "Mine", isChosen: choice(for: hunk.id) == .mine)
                hunkText(hunk.theirsText, label: "Theirs", isChosen: choice(for: hunk.id) == .theirs)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func hunkText(_ text: String, label: String, isChosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(text.isEmpty ? "(deleted)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isChosen ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isChosen ? 2 : 1)
        )
    }

    private func choice(for id: Int) -> MergeSide {
        choices[id] ?? .mine
    }

    private func choiceBinding(for id: Int) -> Binding<MergeSide> {
        Binding(
            get: { choices[id] ?? .mine },
            set: { choices[id] = $0 }
        )
    }
}

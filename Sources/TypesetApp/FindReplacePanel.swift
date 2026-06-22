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

struct FindReplacePanel: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var isCaseSensitive: Bool
    var currentIndex: Int?
    var matchCount: Int
    var onFindChanged: () -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field {
        case find
        case replace
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .find)
                    .onSubmit(onNext)
                    .onChange(of: findText) { _, _ in
                        onFindChanged()
                    }

                Text(matchStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Button(action: onPrevious) {
                    Label("Previous", systemImage: "chevron.up")
                }
                .labelStyle(.iconOnly)
                .help("Previous Match")
                .disabled(matchCount == 0)

                Button(action: onNext) {
                    Label("Next", systemImage: "chevron.down")
                }
                .labelStyle(.iconOnly)
                .help("Next Match")
                .disabled(matchCount == 0)

                Button(action: onClose) {
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .help("Close")
            }

            HStack(spacing: 8) {
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .replace)
                    .onSubmit(onReplace)

                Toggle(isOn: $isCaseSensitive) {
                    Text("Aa")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.button)
                .help("Match Case")
                .onChange(of: isCaseSensitive) { _, _ in
                    onFindChanged()
                }

                Button("Replace", action: onReplace)
                    .disabled(matchCount == 0)

                Button("All", action: onReplaceAll)
                    .disabled(matchCount == 0)
            }
        }
        .padding(10)
        .frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
        .onAppear {
            focusedField = .find
            onFindChanged()
        }
    }

    private var matchStatus: String {
        guard !findText.isEmpty else { return "" }
        guard matchCount > 0 else { return "0" }
        if let currentIndex {
            return "\(currentIndex)/\(matchCount)"
        }
        return "\(matchCount)"
    }
}


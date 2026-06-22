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

struct DiagnosticLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info
        case warning
        case error
    }

    var id = UUID()
    var date = Date()
    var title: String
    var message: String
    var level: Level
    var diagnostic: TypstSourceDiagnostic? = nil

    var isError: Bool {
        level == .error
    }
}

#if os(iOS)
struct PDFShareItem: Identifiable {
    let id = UUID()
    var url: URL
}

struct PDFShareSheet: UIViewControllerRepresentable {
    var url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

struct DiagnosticLogSlideOver: View {
    var entries: [DiagnosticLogEntry]
    var isPresented: Bool
    var onSelectDiagnostic: (TypstSourceDiagnostic) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if isPresented {
                    panel
                        .frame(width: min(max(proxy.size.width * 0.36, 320), 460))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(isPresented)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                        .font(.headline)

                    Text("Typst \(TypstRuntime.typstVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .opacity(0.45)

            if entries.isEmpty {
                ContentUnavailableView("No Logs", systemImage: "checkmark.circle", description: Text("Compilation messages will appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            DiagnosticLogRow(entry: entry, onSelectDiagnostic: onSelectDiagnostic)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 28, x: -12, y: 0)
        .ignoresSafeArea(.container, edges: [.bottom, .trailing])
    }
}

struct DiagnosticLogRow: View {
    var entry: DiagnosticLogEntry
    var onSelectDiagnostic: (TypstSourceDiagnostic) -> Void = { _ in }

    var body: some View {
        Button {
            if let diagnostic = entry.diagnostic {
                onSelectDiagnostic(diagnostic)
            }
        } label: {
            content
        }
        .buttonStyle(.plain)
        .disabled(entry.diagnostic == nil)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)

                Text(entry.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Spacer(minLength: 8)

                Text(entry.date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.26), lineWidth: 1)
        }
    }

    private var icon: String {
        switch entry.level {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.octagon"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var rowBackground: some ShapeStyle {
        color.opacity(0.11)
    }
}


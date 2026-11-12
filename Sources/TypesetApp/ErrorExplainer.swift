// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Plain-language explanations of compiler diagnostics from the system's
/// on-device language model.
///
/// Typst's messages are precise but terse, and they assume its vocabulary
/// ("expected content, found array"). The model runs on the device, so the
/// message never leaves it; on hardware without Apple Intelligence, or with it
/// turned off, the feature is simply absent.
enum ErrorExplainer {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    static func explain(title: String, message: String) async throws -> String {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: """
            You explain error and warning messages from the Typst typesetting \
            compiler to someone writing a document. In two or three short \
            sentences, say what the message means and what the writer most \
            likely needs to change. Do not invent function names or syntax. \
            If you are unsure of the cause, say so.
            """)
        let response = try await session.respond(to: "\(title)\n\n\(message)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

/// The Explain control under an error or warning in the log, and the
/// explanation once asked for.
struct DiagnosticExplanationView: View {
    var entry: DiagnosticLogEntry

    private enum Phase: Equatable {
        case idle
        case working
        case explained(String)
        case failed
    }

    @State private var phase: Phase = .idle

    var body: some View {
        switch phase {
        case .idle:
            Button("Explain", systemImage: "sparkles", action: explain)
                .buttonStyle(.borderless)
                .font(.caption)
        case .working:
            ProgressView()
                .controlSize(.small)
        case .explained(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Written by an on-device model. It can be wrong.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text("No explanation is available for this message.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func explain() {
        phase = .working
        let title = entry.title
        let message = entry.message
        Task {
            do {
                phase = .explained(try await ErrorExplainer.explain(title: title, message: message))
            } catch {
                phase = .failed
            }
        }
    }
}

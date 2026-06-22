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

enum WorkspaceViewMode: String {
    case source
    case preview
    case both
}

/// An unresolved conflict: the open file was changed on disk by another program
/// while it had unsaved in-app edits. Drives the overwrite/revert prompt.
struct DiskConflict: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let diskText: String

    var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}

enum SplitBehavior: String, CaseIterable, Identifiable {
    case automatic
    case sideBySide
    case stacked

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .sideBySide:
            return "Side by Side"
        case .stacked:
            return "Stacked"
        }
    }

    var symbolName: String {
        switch self {
        case .automatic:
            return "rectangle.split.2x1"
        case .sideBySide:
            return "rectangle.split.2x1"
        case .stacked:
            return "rectangle.split.1x2"
        }
    }
}

enum SplitOrientation: Hashable {
    case horizontal
    case vertical
}

enum FindDirection {
    case next
    case previous
}

struct PendingEditorState: Equatable {
    var selectedFile: String
    var cursorLocation: Int
    var cursorLength: Int
}

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}


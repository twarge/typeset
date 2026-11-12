// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The system's Reduce Motion setting. Read at the moment of each change, so
/// turning it on takes effect without relaunching.
enum ReduceMotion {
    @MainActor static var isEnabled: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }
}

/// `withAnimation`, except that with Reduce Motion on the change simply
/// happens. Panels sliding and panes resizing are decoration here; nothing is
/// lost by showing the end state at once.
@MainActor
func withAccessibleAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try withAnimation(ReduceMotion.isEnabled ? nil : animation, body)
}

extension View {
    /// `animation(_:value:)`, honouring Reduce Motion in the same way.
    func accessibleAnimation<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(AccessibleAnimation(animation: animation, value: value))
    }
}

private struct AccessibleAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var animation: Animation?
    var value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

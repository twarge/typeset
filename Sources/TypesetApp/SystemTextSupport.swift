// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if os(macOS)
import AppKit
#endif

/// Keeps Writing Tools to prose.
///
/// Writing Tools rewrites whatever text it is given, and a Typst file is
/// mostly things that must survive a rewrite untouched: function calls, math,
/// labels, raw blocks. The language service already tells the editor which
/// ranges are prose, for spell checking; everything outside them is declared
/// off limits here.
enum WritingToolsRanges {
    /// The parts of `enclosing` that Writing Tools must leave alone. With no
    /// current prose ranges, that is all of it: better to offer nothing than
    /// to rewrite markup.
    static func ignored(in enclosing: NSRange, prose: [NSRange], proseIsCurrent: Bool) -> [NSValue] {
        guard proseIsCurrent else { return [NSValue(range: enclosing)] }

        var ignored: [NSValue] = []
        var cursor = enclosing.location
        let end = NSMaxRange(enclosing)
        for range in prose.sorted(by: { $0.location < $1.location }) {
            let start = max(range.location, enclosing.location)
            let stop = min(NSMaxRange(range), end)
            guard start < stop else { continue }
            if start > cursor {
                ignored.append(NSValue(range: NSRange(location: cursor, length: start - cursor)))
            }
            cursor = max(cursor, stop)
        }
        if cursor < end {
            ignored.append(NSValue(range: NSRange(location: cursor, length: end - cursor)))
        }
        return ignored
    }
}

#if os(macOS)
/// The Mac's shared find pasteboard: what was last searched for in any app is
/// what Find starts with in the next one, and ⌘E sets it from the selection.
enum FindPasteboard {
    static var string: String? {
        get {
            let value = NSPasteboard(name: .find).string(forType: .string)
            return value?.isEmpty == false ? value : nil
        }
        set {
            guard let newValue, !newValue.isEmpty else { return }
            let pasteboard = NSPasteboard(name: .find)
            guard pasteboard.string(forType: .string) != newValue else { return }
            pasteboard.clearContents()
            pasteboard.setString(newValue, forType: .string)
        }
    }
}
#endif

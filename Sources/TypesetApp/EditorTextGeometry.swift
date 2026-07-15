// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform TextKit 2 geometry helpers.
///
/// `NSTextLayoutManager` and friends are the same classes on macOS and iOS, so
/// everything here compiles for both platforms — this is the seed of the shared
/// editor core. The iOS editor (TextKit 2) uses these today. The macOS editor
/// deliberately runs TextKit 1 — TK2's NSTextView has architecturally unstable
/// height estimation/scrolling (see the parked "macOS editor TextKit 2
/// migration" stash) — so shared feature code should reach geometry through an
/// abstraction that can back onto either engine, not through these directly.
/// On a TextKit 2 view, never read `layoutManager` — merely accessing that
/// property silently downgrades the view to TextKit 1.
///
/// All returned frames are in text-container coordinates; callers add the
/// view's text-container origin/inset to convert to view coordinates.
enum EditorTextGeometry {
    /// Converts a UTF-16 character range into the layout manager's text range.
    static func textRange(forCharacterRange range: NSRange, in layoutManager: NSTextLayoutManager) -> NSTextRange? {
        guard range.location >= 0, range.length >= 0,
              let contentManager = layoutManager.textContentManager,
              let start = contentManager.location(layoutManager.documentRange.location, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// The UTF-16 character offset of a text location from the document start.
    static func characterOffset(of location: NSTextLocation, in layoutManager: NSTextLayoutManager) -> Int? {
        guard let contentManager = layoutManager.textContentManager else { return nil }
        return contentManager.offset(from: layoutManager.documentRange.location, to: location)
    }

    /// Union of the visual-line segment frames for the range — the TextKit 2
    /// analog of `boundingRect(forGlyphRange:in:)`.
    static func boundingRect(forCharacterRange range: NSRange, in layoutManager: NSTextLayoutManager) -> CGRect? {
        var union: CGRect?
        enumerateSegmentFrames(forCharacterRange: range, in: layoutManager) { frame in
            union = union.map { $0.union(frame) } ?? frame
        }
        return union
    }

    /// One frame per visual line the range touches — the TextKit 2 analog of
    /// `enumerateLineFragments(forGlyphRange:)` for callers that only need
    /// per-line vertical extents.
    static func visualLineFrames(forCharacterRange range: NSRange, in layoutManager: NSTextLayoutManager) -> [CGRect] {
        var frames: [CGRect] = []
        enumerateSegmentFrames(forCharacterRange: range, in: layoutManager) { frames.append($0) }
        return frames
    }

    /// Zero-width caret frame at a character offset.
    static func caretRect(atCharacterOffset offset: Int, in layoutManager: NSTextLayoutManager) -> CGRect? {
        guard offset >= 0,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(layoutManager.documentRange.location, offsetBy: offset) else { return nil }
        let caretRange = NSTextRange(location: location)
        layoutManager.ensureLayout(for: caretRange)
        var rect: CGRect?
        layoutManager.enumerateTextSegments(in: caretRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame
            return false
        }
        if rect == nil,
           let charFrame = boundingRect(forCharacterRange: NSRange(location: offset, length: 1), in: layoutManager) {
            // Fall back to the leading edge of the character at the offset.
            rect = CGRect(x: charFrame.minX, y: charFrame.minY, width: 0, height: charFrame.height)
        }
        return rect
    }

    private static func enumerateSegmentFrames(
        forCharacterRange range: NSRange,
        in layoutManager: NSTextLayoutManager,
        using body: (CGRect) -> Void
    ) {
        guard let textRange = textRange(forCharacterRange: range, in: layoutManager) else { return }
        layoutManager.ensureLayout(for: textRange)
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            body(frame)
            return true
        }
    }
}

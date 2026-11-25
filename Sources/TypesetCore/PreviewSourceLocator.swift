import Foundation

/// Finds where on the rendered pages a place in the source came out: the
/// reverse of clicking the preview to move the caret, from the same list of
/// page rectangles and the source ranges that drew them.
public enum PreviewSourceLocator {
    /// A point on a page, in points from the page's top-left corner.
    public struct Spot: Equatable, Sendable {
        public var page: Int
        public var x: Double
        public var y: Double

        public init(page: Int, x: Double, y: Double) {
            self.page = page
            self.x = x
            self.y = y
        }
    }

    /// The middle of what `location` (a UTF-16 offset into the file at
    /// `path`) drew. The rectangle whose range holds the location wins, the
    /// tightest where several do (a glyph over the box it sits in). Markup
    /// that draws nothing itself (`#set`, a comment, the space between
    /// paragraphs) goes to the nearest thing in the file that did. Nil when
    /// nothing on the pages came from that file.
    public static func spot(for location: Int, path: String, in rects: [PreviewSourceRect]) -> Spot? {
        var best: PreviewSourceRect?
        var bestScore = (gap: Int.max, length: Int.max)
        for rect in rects where rect.range.path == path {
            guard (rect.x + rect.y + rect.width + rect.height).isFinite, rect.width > 0, rect.height > 0 else { continue }
            let start = rect.range.start
            let end = max(start, rect.range.end)
            // A range holds its start but not its end, so a click between two
            // glyphs belongs to the one after it; an empty range (a glyph
            // that code produced) holds only its own offset.
            let holds = location >= start && (location < end || location == start)
            let gap = holds ? 0 : location < start ? start - location : location - end + 1
            let score = (gap: gap, length: end - start)
            if score < bestScore {
                best = rect
                bestScore = score
            }
        }
        return best.map { Spot(page: $0.page, x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
    }
}

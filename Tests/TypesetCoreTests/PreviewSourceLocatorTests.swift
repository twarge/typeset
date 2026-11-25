import XCTest
@testable import TypesetCore

final class PreviewSourceLocatorTests: XCTestCase {
    private func rect(_ start: Int, _ end: Int, page: Int = 0, x: Double, y: Double = 100,
                      width: Double = 10, height: Double = 10, path: String = "main.typ") -> PreviewSourceRect {
        PreviewSourceRect(page: page, x: x, y: y, width: width, height: height,
                          range: SourceRange(path: path, start: start, end: end))
    }

    func testAPositionInsideAGlyphGoesToThatGlyph() {
        let rects = [rect(10, 11, x: 0), rect(11, 12, x: 10), rect(12, 13, x: 20)]
        let spot = PreviewSourceLocator.spot(for: 11, path: "main.typ", in: rects)
        XCTAssertEqual(spot, .init(page: 0, x: 15, y: 105))
    }

    func testTheGlyphWinsOverTheBoxAroundIt() {
        let rects = [rect(0, 100, x: 0, width: 400, height: 300), rect(40, 41, page: 0, x: 50)]
        XCTAssertEqual(PreviewSourceLocator.spot(for: 40, path: "main.typ", in: rects)?.x, 55)
    }

    func testMarkupThatDrawsNothingGoesToTheNearestThingDrawn() {
        // "#set …" at 0..<30 draws nothing; text starts at 30 on page 0 and
        // more follows far away on page 1.
        let rects = [rect(30, 31, x: 0), rect(500, 501, page: 1, x: 0)]
        XCTAssertEqual(PreviewSourceLocator.spot(for: 5, path: "main.typ", in: rects)?.page, 0)
        XCTAssertEqual(PreviewSourceLocator.spot(for: 480, path: "main.typ", in: rects)?.page, 1)
    }

    func testAGlyphThatCodeProducedIsFoundAtItsOffset() {
        let rects = [rect(20, 20, x: 0), rect(20, 20, x: 10), rect(60, 61, x: 200)]
        XCTAssertEqual(PreviewSourceLocator.spot(for: 20, path: "main.typ", in: rects)?.x, 5)
    }

    func testOnlyTheClickedFileCounts() {
        let rects = [rect(0, 1, x: 0, path: "chapter.typ")]
        XCTAssertNil(PreviewSourceLocator.spot(for: 0, path: "main.typ", in: rects))
        XCTAssertNotNil(PreviewSourceLocator.spot(for: 0, path: "chapter.typ", in: rects))
    }
}

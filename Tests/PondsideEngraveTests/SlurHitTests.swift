import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// `slur.svg` is LilyPond 2.26 output of
/// `{ c'4( d e f) g\( a b c\) }` (line 2): the slur is linked to its `(`
/// at character 5, the phrasing slur to `\(` at 15.
final class SlurHitTests: XCTestCase {
    func testSlurIsHitOnItsCurveOnly() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("slur.svg")))
        let slur = try XCTUnwrap(page.graphics.first { $0.link?.line == 2 && $0.link?.character == 5 })
        let isSlur: (PointAndClickLocation) -> Bool = { $0.line == 2 && [5, 15].contains($0.character) }

        // The middle of its box is empty paper above the noteheads.
        let middle = Point(slur.bounds.midX, slur.bounds.midY)
        XCTAssertEqual(page.hitTest(middle, tolerance: 0.1)?.link, slur.link, "the box alone takes the click")
        XCTAssertNotEqual(page.hitTest(middle, tolerance: 0.1, byOutline: isSlur)?.link, slur.link)

        // Its lowest point, midway along, is on the curve.
        guard case .path(let path, _, _, _) = slur.content else { return XCTFail("slur is a path") }
        let points = path.flattened().flatMap { $0 }
        let bottom = try XCTUnwrap(points.filter { abs($0.x - slur.bounds.midX) < 1 }.max { $0.y < $1.y })
        XCTAssertEqual(page.hitTest(bottom, tolerance: 0.1, byOutline: isSlur)?.link, slur.link)
    }

    func testFilledShapeContainsItsInside() {
        let square = Graphic(content: .path(.rect(Rect(x: 0, y: 0, width: 2, height: 2)), fill: RGBA(0, 0, 0),
                                            stroke: nil, style: StrokeStyle(width: 0)),
                             bounds: Rect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertTrue(square.shapeContains(Point(1, 1), tolerance: 0))
        XCTAssertTrue(square.shapeContains(Point(2.05, 1), tolerance: 0.1))
        XCTAssertFalse(square.shapeContains(Point(2.5, 1), tolerance: 0.1))
    }
}

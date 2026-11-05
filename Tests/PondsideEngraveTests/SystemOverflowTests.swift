import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// `overflow.svg` is LilyPond 2.26 output of four systems on one staff with
/// `\autoLineBreaksOff`; the third holds more notes than fit and runs
/// 44.5 staff spaces past the others' end (110.92).
final class SystemOverflowTests: XCTestCase {
    func testFindsTheSystemRunningIntoTheMargin() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("overflow.svg")))
        let found = SystemOverflow.detect(in: [page])
        XCTAssertEqual(found.count, 1)
        let o = try XCTUnwrap(found.first)
        XCTAssertEqual(o.page, 0)
        XCTAssertEqual(o.edge, 110.92, accuracy: 0.01)
        XCTAssertEqual(o.right, 155.39, accuracy: 0.01)
        XCTAssertEqual(o.amountMM, (155.39 - 110.92) * page.widthMM / page.viewBox.width, accuracy: 0.05)
        // Its first glyph is the system's first note, on line 3.
        XCTAssertEqual(o.first?.line, 3)
    }

    func testJustifiedSystemsDoNotOverflow() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("slur.svg")))
        XCTAssertTrue(SystemOverflow.detect(in: [page]).isEmpty)
    }

    func testTheSharedEdgeNeedsTwoStaves() {
        XCTAssertNil(SystemOverflow.justifiedEdge([100]))
        XCTAssertEqual(SystemOverflow.justifiedEdge([100, 100.01, 120]) ?? 0, 100.01, accuracy: 1e-9)
        XCTAssertNil(SystemOverflow.justifiedEdge([100, 120]))
    }
}

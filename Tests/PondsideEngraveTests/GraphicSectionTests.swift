import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// The ⌥-drag section's geometry: one staff across systems, its edges, and
/// the fractions the graphic skill gates a drawing with.
final class GraphicSectionTests: XCTestCase {
    private let link = PointAndClickLocation(path: "/score.ly", line: 4, character: 5, column: 6)

    private func line(_ x0: Double, _ x1: Double, _ y: Double, link: PointAndClickLocation? = nil) -> Graphic {
        Graphic(content: .path(VectorPath([.move(Point(x0, y)), .line(Point(x1, y))]),
                               fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                bounds: Rect(x: x0, y: y, width: x1 - x0, height: 0), link: link)
    }

    private func staff(_ top: Double, x0: Double = 0, x1: Double = 100) -> Staff {
        Staff(lineYs: (0..<5).map { top + Double($0) }, minX: x0, maxX: x1)
    }

    /// Three systems with their staves drawn, and the graphics of a fourth,
    /// hidden staff below each; a short five-line symbol (the lines a
    /// collection draws on a hidden staff) lies between systems one and two.
    private func hiddenStaffPage() -> EngravedPage {
        var graphics: [Graphic] = []
        for top in [10.0, 40.0, 70.0] {
            for i in 0..<5 { graphics.append(line(0, 100, top + Double(i))) }
        }
        for i in 0..<5 { graphics.append(line(0, 10, 24 + Double(i))) }
        for top in [20.0, 50.0, 80.0] {
            graphics.append(line(20, 80, top + 2, link: link))
        }
        return EngravedPage(widthMM: 210, heightMM: 297, viewBox: Rect(x: 0, y: 0, width: 100, height: 140),
                            graphics: graphics)
    }

    /// Two systems (staves at 10–14 and 40–44), each with a linked graphic
    /// piece from 20 to 80 and 20 to 70.
    private func page() -> EngravedPage {
        var graphics: [Graphic] = []
        for top in [10.0, 40.0] {
            for i in 0..<5 { graphics.append(line(0, 100, top + Double(i))) }
        }
        graphics.append(line(20, 80, 12, link: link))
        graphics.append(line(20, 70, 42, link: link))
        return EngravedPage(widthMM: 210, heightMM: 297, viewBox: Rect(x: 0, y: 0, width: 100, height: 140),
                            graphics: graphics)
    }

    func testASectionFromOneSystemToTheNext() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(30, 12)), to: (0, Point(60, 42)), link: link))
        XCTAssertEqual(section.systems.count, 2)
        XCTAssertEqual(section.systems.map(\.ordinal), [0, 1])
        XCTAssertEqual(section.from.page, 0)
        XCTAssertEqual(section.from.pageX, 30, accuracy: 0.001)
        XCTAssertEqual(section.from.fraction, 10.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(section.to.pageX, 60, accuracy: 0.001)
        XCTAssertEqual(section.to.fraction, 40.0 / 50.0, accuracy: 0.001)
        XCTAssertEqual(section.systems[0].pageX, 30...80)
        XCTAssertEqual(section.systems[1].pageX, 20...60)
        XCTAssertEqual(section.systems[0].fraction.lowerBound, 10.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(section.systems[1].fraction.upperBound, 40.0 / 50.0, accuracy: 0.001)
        XCTAssertEqual(section.staffSpaceRange, -2...2)
    }

    func testASectionOnOneSystem() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(30, 12)), to: (0, Point(50, 12)), link: link))
        XCTAssertEqual(section.systems.count, 1)
        XCTAssertEqual(section.systems[0].pageX, 30...50)
        XCTAssertEqual(section.systems[0].fraction.lowerBound, 10.0 / 60.0, accuracy: 0.001)
        XCTAssertEqual(section.systems[0].fraction.upperBound, 30.0 / 60.0, accuracy: 0.001)
    }

    func testADragUpwardsIsTheSameSectionTopDown() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(40, 42)), to: (0, Point(50, 12)), link: link))
        XCTAssertEqual(section.from.pageX, 50, accuracy: 0.001)
        XCTAssertEqual(section.to.pageX, 40, accuracy: 0.001)
        XCTAssertEqual(section.systems.map(\.pageX), [50...80, 20...40])
    }

    func testWithoutAGraphicTheStaffIsThePiece() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(30, 12)), to: (0, Point(50, 12)), link: nil))
        XCTAssertEqual(section.from.piece, Rect(x: 0, y: 10, width: 100, height: 4))
        XCTAssertEqual(section.from.fraction, 0.3, accuracy: 0.001)
        XCTAssertEqual(section.to.fraction, 0.5, accuracy: 0.001)
    }
}

extension GraphicSectionTests {
    func testASameSystemMarqueeDrawnBackwardsIsStillLeftToRight() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(50, 12)), to: (0, Point(30, 12)), link: link))
        XCTAssertEqual(section.from.pageX, 30, accuracy: 0.001)
        XCTAssertEqual(section.to.pageX, 50, accuracy: 0.001)
        XCTAssertEqual(section.systems[0].pageX, 30...50)
    }

    func testAShortStaffSymbolDoesNotJoinTwoSystems() {
        let page = hiddenStaffPage()
        XCTAssertEqual(EngravedPage.systems(of: page.staves).count, 3)
    }

    func testAGraphicOnAHiddenStaffMarksThatStaff() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [hiddenStaffPage()], from: (0, Point(20, 22)), to: (0, Point(60, 22)), link: link))
        XCTAssertEqual(section.systems.count, 1)
        XCTAssertEqual(section.from.staff.top, 20, accuracy: 0.001)
        XCTAssertEqual(section.from.staff.bottom, 24, accuracy: 0.001)
        XCTAssertEqual(section.from.staff.minX, 0, accuracy: 0.001)
        XCTAssertEqual(section.from.staff.maxX, 100, accuracy: 0.001)
        XCTAssertEqual(section.staffSpaceRange, -2...2)
    }

    func testAGraphicOnAHiddenStaffSpansSystemsAtTheDrawing() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [hiddenStaffPage()], from: (0, Point(20, 22)), to: (0, Point(60, 52)), link: link))
        XCTAssertEqual(section.systems.count, 2)
        XCTAssertEqual(section.systems.map(\.staff.top), [20, 50])
        XCTAssertEqual(section.systems.map(\.staff.bottom), [24, 54])
    }
}

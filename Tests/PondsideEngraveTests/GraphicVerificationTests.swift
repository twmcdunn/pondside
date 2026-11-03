import XCTest
import PondsideCore
@testable import PondsideEngrave

final class GraphicVerificationTests: XCTestCase {
    private func line(_ x0: Double, _ x1: Double, _ y: Double,
                      link: PointAndClickLocation? = nil) -> Graphic {
        Graphic(content: .path(VectorPath([.move(Point(x0, y)), .line(Point(x1, y))]),
                               fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                bounds: Rect(x: x0, y: y, width: x1 - x0, height: 0), link: link)
    }

    private func dot(_ x: Double, _ y: Double, radius: Double = 0.25,
                     link: PointAndClickLocation? = nil) -> Graphic {
        Graphic(content: .path(.ellipse(center: Point(x, y), rx: radius, ry: radius),
                               fill: .black, stroke: nil, style: StrokeStyle(width: 0)),
                bounds: Rect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius),
                link: link)
    }

    private func page(_ graphics: [Graphic] = [], staffTops: [Double] = [10]) -> EngravedPage {
        let staves = staffTops.flatMap { top in
            (0..<5).map { line(0, 100, top + Double($0)) }
        }
        return EngravedPage(widthMM: 210, heightMM: 297,
                            viewBox: Rect(x: 0, y: 0, width: 100, height: 140),
                            graphics: staves + graphics)
    }

    private func section(pages: [EngravedPage], from: Point = Point(20, 12),
                         to: Point = Point(60, 12)) throws -> GraphicSection {
        try XCTUnwrap(GraphicSection.make(pages: pages, from: (0, from), to: (0, to), link: nil))
    }

    func testIdenticalPagesHaveNoVisualChangeRegardlessOfElementOrder() throws {
        let before = page([dot(30, 12), dot(80, 12)])
        let after = page([dot(80, 12), dot(30, 12)])
        let report = GraphicVerification.compare(before: [before], after: [after],
                                                 section: try section(pages: [before]))
        XCTAssertFalse(report.selectedChanged)
        XCTAssertTrue(report.outsideUnchanged)
        XCTAssertEqual(report.selectedAdded, 0)
        XCTAssertEqual(report.selectedRemoved, 0)
        XCTAssertEqual(report.changedCrossing, 0)
        XCTAssertEqual(report.status, .noSelectedChange)
        XCTAssertFalse(report.ok)
    }

    func testLocalAddedDotBeyondStaffLinesIsASelectedChange() throws {
        let before = page()
        // Three staff spaces below the five-line staff, inside the four-space band.
        let after = page([dot(30, 17)])
        let report = GraphicVerification.compare(before: [before], after: [after],
                                                 section: try section(pages: [before]))
        XCTAssertTrue(report.selectedChanged)
        XCTAssertTrue(report.outsideUnchanged)
        XCTAssertEqual(report.selectedAdded, 1)
        XCTAssertEqual(report.selectedRemoved, 0)
        XCTAssertEqual(report.selectedChangedCount, 1)
        XCTAssertEqual(report.systems[0].added, 1)
        XCTAssertEqual(report.status, .ok)
        XCTAssertTrue(report.ok)
    }

    func testLinkOnlyChangeIsVisuallyIdentical() throws {
        let oldLink = PointAndClickLocation(path: "/score.ly", line: 4, character: 5, column: 6)
        let newLink = PointAndClickLocation(path: "/score.ly", line: 9, character: 12, column: 13)
        let before = page([dot(30, 12, link: oldLink)])
        let after = page([dot(30, 12, link: newLink)])
        let report = GraphicVerification.compare(before: [before], after: [after],
                                                 section: try section(pages: [before]))
        XCTAssertFalse(report.selectedChanged)
        XCTAssertTrue(report.outsideUnchanged)
        XCTAssertEqual(report.systems[0].before, report.systems[0].after)
        XCTAssertEqual(report.systems[0].changed, 0)
        XCTAssertEqual(report.status, .noSelectedChange)
    }

    func testOutsideAddedDotBreaksOutsideInvariance() throws {
        let before = page()
        let after = page([dot(80, 12)])
        let report = GraphicVerification.compare(before: [before], after: [after],
                                                 section: try section(pages: [before]))
        XCTAssertFalse(report.selectedChanged)
        XCTAssertFalse(report.outsideUnchanged)
        XCTAssertEqual(report.outsideAdded, 1)
        XCTAssertEqual(report.outsideRemoved, 0)
        XCTAssertEqual(report.status, .outsideChanged)
        XCTAssertFalse(report.ok)
    }

    func testChangedCrossingPathIsInconclusiveWithoutChangingOutsideCounts() throws {
        let before = page([dot(80, 12), line(50, 70, 12)])
        let after = page([dot(80, 12), line(50, 70, 13)])
        let report = GraphicVerification.compare(before: [before], after: [after],
                                                 section: try section(pages: [before]))
        XCTAssertEqual(report.changedCrossing, 1)
        XCTAssertTrue(report.selectedChanged)
        XCTAssertTrue(report.outsideUnchanged)
        XCTAssertEqual(report.outsideAdded, 0)
        XCTAssertEqual(report.outsideRemoved, 0)
        XCTAssertEqual(report.status, .inconclusive)
        XCTAssertFalse(report.ok)
    }

    func testMultipleSystemsEachHaveTheirOwnReport() throws {
        let before = page(staffTops: [10, 40])
        let after = page([dot(40, 12), dot(20, 42)], staffTops: [10, 40])
        let section = try section(pages: [before], from: Point(30, 12), to: Point(50, 42))
        let report = GraphicVerification.compare(before: [before], after: [after], section: section)
        XCTAssertEqual(report.systems.count, 2)
        XCTAssertEqual(report.systems.map(\.ordinal), [0, 1])
        XCTAssertEqual(report.systems.map(\.added), [1, 1])
        XCTAssertEqual(report.systems.map(\.removed), [0, 0])
        XCTAssertEqual(report.selectedAdded, 2)
        XCTAssertEqual(report.selectedChangedCount, 2)
        XCTAssertTrue(report.selectedChanged)
        XCTAssertTrue(report.outsideUnchanged)
        XCTAssertTrue(report.ok)
    }

    func testAddedAndRemovedEmptyPagesAreOutsideChanges() throws {
        let score = page()
        let empty = page(staffTops: [])
        let section = try section(pages: [score])

        let removed = GraphicVerification.compare(before: [score, empty], after: [score], section: section)
        XCTAssertEqual(removed.outsideRemovedPages, 1)
        XCTAssertFalse(removed.outsideUnchanged)
        XCTAssertEqual(removed.status, .outsideChanged)

        let added = GraphicVerification.compare(before: [score], after: [score, empty], section: section)
        XCTAssertEqual(added.outsideAddedPages, 1)
        XCTAssertFalse(added.outsideUnchanged)
        XCTAssertEqual(added.status, .outsideChanged)
    }
}

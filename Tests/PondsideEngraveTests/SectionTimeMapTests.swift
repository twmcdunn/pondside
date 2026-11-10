import Foundation
import XCTest
import PondsideCore
import PondsideTiming
@testable import PondsideEngrave

final class SectionTimeMapTests: XCTestCase {
    private func line(_ x0: Double, _ x1: Double, _ y: Double) -> Graphic {
        Graphic(content: .path(VectorPath([.move(Point(x0, y)), .line(Point(x1, y))]),
                               fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                bounds: Rect(x: x0, y: y, width: x1 - x0, height: 0))
    }

    private func note(_ x: Double, _ y: Double, line: Int, character: Int) -> Graphic {
        let bounds = Rect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)
        return Graphic(content: .path(VectorPath([.move(Point(bounds.minX, bounds.minY)),
                                                 .line(Point(bounds.maxX, bounds.maxY))]),
                                       fill: .black, stroke: nil, style: StrokeStyle(width: 0)),
                       bounds: bounds,
                       link: PointAndClickLocation(path: "/score.ly", line: line, character: character, column: 1))
    }

    private func page() -> EngravedPage {
        var graphics: [Graphic] = []
        for y in stride(from: 10.0, through: 14.0, by: 1.0) { graphics.append(line(0, 100, y)) }
        graphics.append(note(20, 12, line: 1, character: 0))
        graphics.append(note(60, 12, line: 1, character: 4))
        graphics.append(note(80, 12, line: 1, character: 8))
        return EngravedPage(widthMM: 210, heightMM: 297,
                            viewBox: Rect(x: 0, y: 0, width: 100, height: 140), graphics: graphics)
    }

    private func log() -> TimingLog {
        TimingLog(rows: [
            .init(moment: Rational(0), bar: 1, kind: .note(staff: "flute", midi: 60),
                  origin: .init(file: "/score.ly", line: 1, character: 0)),
            .init(moment: Rational(3), bar: 1, kind: .note(staff: "flute", midi: 62),
                  origin: .init(file: "/score.ly", line: 1, character: 4)),
            .init(moment: Rational(4), bar: 1, kind: .note(staff: "flute", midi: 64),
                  origin: .init(file: "/score.ly", line: 1, character: 8)),
        ])
    }

    func testAnEdgeBetweenNotesInterpolatesTheMoment() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(20, 12)), to: (0, Point(50, 12)), link: nil))
        let map = SectionTimeMap(log: log(), pages: [page()])
        let from = try XCTUnwrap(map.edge(at: section.from, staffName: "flute"))
        let to = try XCTUnwrap(map.edge(at: section.to, staffName: "flute"))
        XCTAssertEqual(from.moment, Rational(0))
        XCTAssertEqual(to.moment, Rational(9, 4))
        XCTAssertEqual(to.bar, 1)
    }

    func testAnEdgeAtANoteUsesThatNote() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(60, 12)), to: (0, Point(80, 12)), link: nil))
        let map = SectionTimeMap(log: log(), pages: [page()])
        XCTAssertEqual(map.edge(at: section.from, staffName: "flute")?.moment, Rational(3))
        XCTAssertEqual(map.edge(at: section.to, staffName: "flute")?.moment, Rational(4))
    }

    func testWithoutMatchingNotesThereIsNoEdge() throws {
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page()], from: (0, Point(20, 12)), to: (0, Point(50, 12)), link: nil))
        XCTAssertNil(SectionTimeMap(log: TimingLog(rows: []), pages: [page()])
            .edge(at: section.from, staffName: "flute"))
    }

    func testAHiddenGraphicsStaffNeverInterpolatesAcrossSystems() throws {
        let link = PointAndClickLocation(path: "/graphics.ily", line: 1, character: 0, column: 1)
        var graphics: [Graphic] = []
        for y in stride(from: 10.0, through: 14.0, by: 1.0) { graphics.append(line(0, 100, y)) }
        for y in stride(from: 40.0, through: 44.0, by: 1.0) { graphics.append(line(0, 100, y)) }
        for (line, ys) in [(1, [12.0]), (2, [42.0])] {
            for (x, character) in [(20.0, 0), (60.0, 4), (80.0, 8)] {
                graphics.append(note(x, ys[0], line: line, character: character))
            }
        }
        graphics.append(Graphic(content: .path(VectorPath([.move(Point(0, 50)), .line(Point(100, 54))]),
                                                  fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                                bounds: Rect(x: 0, y: 50, width: 100, height: 4), link: link))
        let page = EngravedPage(widthMM: 210, heightMM: 297,
                                viewBox: Rect(x: 0, y: 0, width: 100, height: 140), graphics: graphics)
        let log = TimingLog(rows: [
            .init(moment: Rational(0), bar: 1, kind: .note(staff: "flute", midi: 60),
                  origin: .init(file: "/score.ly", line: 1, character: 0)),
            .init(moment: Rational(3), bar: 1, kind: .note(staff: "flute", midi: 62),
                  origin: .init(file: "/score.ly", line: 1, character: 4)),
            .init(moment: Rational(4), bar: 1, kind: .note(staff: "flute", midi: 64),
                  origin: .init(file: "/score.ly", line: 1, character: 8)),
            .init(moment: Rational(14), bar: 7, kind: .note(staff: "flute", midi: 60),
                  origin: .init(file: "/score.ly", line: 2, character: 0)),
            .init(moment: Rational(17), bar: 7, kind: .note(staff: "flute", midi: 62),
                  origin: .init(file: "/score.ly", line: 2, character: 4)),
            .init(moment: Rational(18), bar: 7, kind: .note(staff: "flute", midi: 64),
                  origin: .init(file: "/score.ly", line: 2, character: 8)),
        ])
        let section = try XCTUnwrap(GraphicSection.make(
            pages: [page], from: (0, Point(20, 52)), to: (0, Point(50, 52)), link: link))
        let map = SectionTimeMap(log: log, pages: [page])
        let edge = try XCTUnwrap(map.edge(at: section.to, staffName: "electronicsGraphics"))
        // x = 50 is ¾ of the way from the note at 20 (moment 14) to the one at 60 (17).
        XCTAssertEqual(edge.moment, Rational(65, 4))
        XCTAssertEqual(edge.bar, 7)
        let moments = try XCTUnwrap(map.systemMoments(page: section.to.page, system: section.to.system))
        XCTAssertEqual(moments.first, Rational(14))
        XCTAssertEqual(moments.last, Rational(18))
    }
}

import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// The legend's markers and clips in the SVG, and what dragging its parts
/// writes (DESIGN.md §11, "Arranging the legend").
final class LegendArrangementTests: XCTestCase {
    /// LilyPond's url-link writes its y-up interval unflipped; the parser
    /// flips it, and a clip group crops what it holds.
    func testMarkersAndClips() {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="210.00mm" height="297.00mm" viewBox="0 0 119.5 169">
        <g transform="translate(10, 20)"><a xlink:href="pondside-legend:example"><rect x="0" y="-1" width="8" height="3" fill="none" stroke="none"/></a></g>
        <g data-pondside-clip="x">
        <g transform="translate(10, 20)"><a xlink:href="pondside-clip:"><rect x="2" y="-4" width="5" height="8" fill="none"/></a></g>
        <g transform="translate(10, 20)"><rect x="0" y="0" width="1" height="1" fill="currentColor"/></g>
        <g transform="translate(10, 20)"><rect x="3" y="0" width="10" height="1" fill="currentColor"/></g>
        </g>
        <g transform="translate(10, 20)"><rect x="0" y="0" width="1" height="1" fill="currentColor"/></g>
        </svg>
        """
        let page = EngravedPage(svg: svg)
        XCTAssertEqual(page.markers, [PageMarker(name: "example", rect: Rect(x: 10, y: 18, width: 8, height: 3))])
        // The first box lies left of the clip (12…17): gone. The second is cut
        // to it; the last is outside the group.
        XCTAssertEqual(page.graphics.count, 2)
        XCTAssertEqual(page.graphics[0].clip, Rect(x: 12, y: 16, width: 5, height: 8))
        XCTAssertEqual(page.graphics[0].bounds, Rect(x: 13, y: 20, width: 4, height: 1))
        XCTAssertNil(page.graphics[1].clip)
    }

    private func sheet() -> (LegendArrangement, LegendArrangement.Sheet) {
        // Two rows; the line from 10 to 110 on a 120-wide page (1 mm = 0.5).
        func m(_ n: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> PageMarker {
            PageMarker(name: n, rect: Rect(x: x, y: y, width: w, height: h))
        }
        var page = EngravedPage(widthMM: 240, heightMM: 340, viewBox: Rect(x: 0, y: 0, width: 120, height: 170), graphics: [])
        page.markers = [
            m("full", 10, 30, 24, 8), m("example", 10, 30, 20, 8), m("words", 34, 31, 40, 6), m("row", 10, 30, 64, 8), m("line", 10, 30, 100, 8),
            m("example", 10, 42, 18, 8), m("words", 34, 43, 40, 6), m("row", 10, 42, 64, 8), m("line", 10, 42, 100, 8),
        ]
        let legend = LegendArrangement(pages: [page])
        return (legend, legend.sheets[0])
    }

    func testRowsAndHandles() {
        let (legend, sheet) = sheet()
        XCTAssertEqual(sheet.rows.map(\.index), [0, 1])
        XCTAssertEqual(sheet.unitsPerMM, 0.5)
        XCTAssertEqual(sheet.rows[0].full?.width, 24)
        XCTAssertNil(sheet.rows[1].full)
        XCTAssertEqual(legend.handle(at: Point(30, 38), on: sheet, tolerance: 0.5), .scale(0))
        XCTAssertEqual(legend.handle(at: Point(10, 34), on: sheet, tolerance: 0.5), .cropLeft(0))
        XCTAssertEqual(legend.handle(at: Point(34, 34), on: sheet, tolerance: 0.5), .wordsLeft)
        XCTAssertEqual(legend.handle(at: Point(74, 34), on: sheet, tolerance: 0.5), .wordsRight)
        XCTAssertEqual(legend.handle(at: Point(50, 40), on: sheet, tolerance: 0.5), .rowGap(0))
        XCTAssertEqual(legend.handle(at: Point(50, 45), on: sheet, tolerance: 0.5), .table)
        XCTAssertNil(legend.handle(at: Point(100, 100), on: sheet, tolerance: 0.5))
    }

    func testTableSnapsItsCentreToThePageCentreUnlessToldNot() {
        let (legend, sheet) = sheet()
        // The table is 10…74 (centre 42); the page centre is 60. A drag of
        // 17 puts it 1 short: it snaps the rest of the way.
        let snapped = legend.drag(.table, on: sheet, from: Point(40, 40), to: Point(57, 40), layout: .init(), examples: [], threshold: 1.5)
        XCTAssertEqual(snapped.layout.x, 36)
        XCTAssertEqual(snapped.guides, [.init(axis: .vertical, at: 60)])
        let free = legend.drag(.table, on: sheet, from: Point(40, 40), to: Point(57, 40), layout: .init(), examples: [], snap: false, threshold: 1.5)
        XCTAssertEqual(free.layout.x, 34)
        XCTAssertTrue(free.guides.isEmpty)
    }

    func testCropAndScale() {
        let (legend, sheet) = sheet()
        // Drag the first example's right edge 2 units (4 mm) left.
        let crop = legend.drag(.cropRight(0), on: sheet, from: Point(30, 34), to: Point(28, 34), layout: .init(),
                               examples: [.init(), .init()], snap: false, threshold: 1)
        XCTAssertEqual(crop.example?.row, 0)
        // The full example is 24 units, 4 to its right already out of view: 12 mm.
        XCTAssertEqual(crop.example?.layout.right ?? 0, 12, accuracy: 0.01)
        // Its right edge to the other example's (28): snapped from 27.6.
        let scale = legend.drag(.scale(0), on: sheet, from: Point(30, 38), to: Point(27.6, 38), layout: .init(),
                                examples: [.init(), .init()], threshold: 1)
        XCTAssertEqual(scale.example?.layout.scale ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(scale.guides, [.init(axis: .vertical, at: 28)])
        let all = legend.drag(.scale(0), on: sheet, from: Point(30, 38), to: Point(40, 38), layout: .init(),
                              examples: [], snap: false, all: true, threshold: 1)
        XCTAssertEqual(all.layout.scale, 1.5)
        XCTAssertNil(all.example)
    }

    func testRowGapFollowsThePointer() {
        let (legend, sheet) = sheet()
        var layout = FrontMatter.LegendLayout()
        layout.rowGap = 4
        let out = legend.drag(.rowGap(0), on: sheet, from: Point(50, 40), to: Point(50, 41), layout: layout, examples: [], threshold: 1)
        XCTAssertEqual(out.layout.rowGap, 6)
        XCTAssertEqual(out.moves.count, 1)
    }

    /// The real definitions engrave: markers on the canvas, the example cropped.
    func testEngravedLegendCarriesMarkers() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-legend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var fm = FrontMatter(FrontMatter.template([.legend]))
        fm = FrontMatter(fm.edits(legendLayout: .init()).apply(to: fm.text))
        fm = FrontMatter(fm.edits(adding: [
            .init(id: "a", title: "A", text: "first", example: FrontMatter.example(music: "\\cadenzaOn c'1 d' e' f'")),
            .init(id: "b", title: "B", text: "second", example: "\\null"),
        ]).apply(to: fm.text))
        fm = FrontMatter(fm.edits(legend: "a", example: .init(left: 5, right: 0, scale: 1)).apply(to: fm.text))
        try fm.text.write(to: dir.appendingPathComponent(FrontMatter.fileName), atomically: true, encoding: .utf8)
        let source = dir.appendingPathComponent("score.ly")
        try "\\version \"2.24.0\"\n\\include \"front-matter.ily\"\n\\score { { c'1 } }\n".write(to: source, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out")
        let result = try await LilyPondEngraver(installation: lily).engrave(source, purpose: .canvas, outputDirectory: out)
        XCTAssertTrue(result.errors.isEmpty, result.messages)
        let pages = try result.outputFiles.filter { $0.pathExtension == "svg" }.map { EngravedPage(svg: try Data(contentsOf: $0)) }
        let legend = LegendArrangement(pages: pages)
        let rows = legend.sheets.flatMap(\.rows)
        XCTAssertEqual(rows.count, 2)
        let first = try XCTUnwrap(rows.first)
        let shown = try XCTUnwrap(first.example), full = try XCTUnwrap(first.full)
        // 5 mm cropped from the left.
        XCTAssertEqual(full.width - shown.width, 5 * legend.sheets[0].unitsPerMM, accuracy: 0.05)
        XCTAssertNil(rows[1].example)
        XCTAssertTrue(pages.flatMap(\.graphics).contains { $0.clip != nil })
    }
}

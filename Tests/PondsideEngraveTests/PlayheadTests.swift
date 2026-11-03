import Foundation
import XCTest
import PondsideCore
import PondsideTiming
@testable import PondsideEngrave

/// The playback head follows the timing log's note origins through the
/// engraved page (DESIGN.md §10, "Notation Lens" / audition).
final class PlayheadTests: XCTestCase {
    private func page(noteheads: [(x: Double, line: Int, character: Int, path: String)]) -> EngravedPage {
        func line(_ y: Double) -> Graphic {
            Graphic(content: .path(VectorPath([.move(Point(0, y)), .line(Point(100, y))]),
                                   fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                    bounds: Rect(x: 0, y: y, width: 100, height: 0))
        }
        var graphics = (10...14).map { line(Double($0)) }
        for head in noteheads {
            let r = Rect(x: head.x - 0.6, y: 11.5, width: 1.2, height: 1)
            graphics.append(Graphic(content: .path(.ellipse(center: Point(head.x, 12), rx: 0.6, ry: 0.5),
                                                   fill: .black, stroke: nil, style: StrokeStyle(width: 0.1)),
                                    bounds: r,
                                    link: PointAndClickLocation(path: head.path, line: head.line,
                                                                character: head.character, column: head.character + 1)))
        }
        return EngravedPage(widthMM: 210, heightMM: 297, viewBox: Rect(x: 0, y: 0, width: 100, height: 140),
                            graphics: graphics)
    }

    private func log(_ notes: [(moment: Rational, line: Int, character: Int)]) -> TimingLog {
        let rows = notes.map { note in
            TimingLog.Row(moment: note.moment, bar: 1, kind: .note(staff: "", midi: 60),
                          origin: TimingLog.Row.Origin(file: "/score.ly", line: note.line, character: note.character))
        }
        return TimingLog(rows: rows)
    }

    /// A real canvas compile: the timing's note origins find the page's
    /// point-and-click glyphs.
    func testARealEngravingGivesTheHeadStops() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-playhead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("score.ly")
        try """
        \\version "2.24.0"
        \\score { \\new Staff \\relative c'' { c4 d e f | g a b c | } \\layout { } }
        """.write(to: file, atomically: true, encoding: .utf8)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas,
                                                                          outputDirectory: dir.appendingPathComponent("out"))
        XCTAssertTrue(result.errors.isEmpty, result.messages)
        let track = PlayheadTrack(log: result.timing, pages: result.pages())
        XCTAssertGreaterThanOrEqual(track.stops.count, 4, "every printed note is a stop")
        XCTAssertTrue(track.stops.allSatisfy { $0.position.x > 0 && $0.position.bottom > $0.position.top })
    }

    func testNoteRowsCarryTheirSourcePosition() {
        let line = "\(TimingDump.marker)0\t1\t@0\tnote\tflute\t60\t/tmp/score.ly\t4\t23\n"
        let log = TimingLog(parsing: line, prefix: TimingDump.marker)
        XCTAssertEqual(log.rows.first?.origin,
                       TimingLog.Row.Origin(file: "/tmp/score.ly", line: 4, character: 23))
    }

    func testTheHeadGlidesBetweenNotesOnOneSystem() {
        let page = page(noteheads: [(20, 4, 5, "/score.ly"), (60, 4, 9, "/score.ly")])
        let track = PlayheadTrack(log: log([(.zero, 4, 5), (Rational(1, 4), 4, 9)]), pages: [page])
        XCTAssertEqual(track.stops.count, 2)
        XCTAssertEqual(track.position(at: 0)?.x, 20)
        XCTAssertEqual(track.position(at: 0.5)?.x, 40, "the head moves along the system")
        XCTAssertEqual(track.position(at: 2)?.x, 60)
        XCTAssertEqual(track.position(at: 2)?.top, 8)
        XCTAssertEqual(track.position(at: 2)?.bottom, 16)
    }

    func testStartingFromABarWaitsOnItsFirstNote() {
        let page = page(noteheads: [(20, 4, 5, "/score.ly"), (60, 4, 9, "/score.ly")])
        let track = PlayheadTrack(log: log([(.zero, 4, 5), (Rational(1, 4), 4, 9)]), pages: [page])
        XCTAssertEqual(track.position(at: 0.5, from: 1)?.x, 60)
    }

    func testARelativeTimingPathFindsTheAbsoluteLink() {
        let page = page(noteheads: [(20, 4, 5, "/private/tmp/score.ly")])
        var rows = [TimingLog.Row(moment: .zero, bar: 1, kind: .note(staff: "", midi: 60),
                                  origin: TimingLog.Row.Origin(file: "/tmp/score.ly", line: 4, character: 5))]
        rows.append(TimingLog.Row(moment: Rational(1, 4), bar: 1, kind: .note(staff: "", midi: 62),
                                  origin: TimingLog.Row.Origin(file: "score.ly", line: 4, character: 5)))
        let track = PlayheadTrack(log: TimingLog(rows: rows), pages: [page])
        XCTAssertEqual(track.stops.count, 1, "symlinked and relative spellings are the same file")
        XCTAssertEqual(track.stops.first?.position.x, 20)
    }
}

import Foundation
import XCTest
import PondsideTiming
@testable import PondsideBridge

/// A click on a graphic drawn by the score's own code (Tests/Scores/
/// large-graphic: `\startGrains` in electronics.ly, drawn by graphics.ily)
/// gives an agent what it needs to change it, and laconic stops ("till 7")
/// land on the right moment.
final class ScoreGraphicTests: XCTestCase {
    private var folder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scores/large-graphic")
    }

    private func files() throws -> [ScoreGraphic.File] {
        try ["electronics.ly", "graphics.ily", "defs.ily"].map { name in
            let url = folder.appendingPathComponent(name)
            return (url.path, try String(contentsOf: url, encoding: .utf8))
        }
    }

    func testAClickedCustomGraphicNamesItsDrawing() throws {
        let all = try files()
        let text = all[0].text
        // electronics.ly:293 `  s4*2 \stopGraphic \startGrains s4*5 \stopGraphic \startSwell | % 4`
        let line = 293, character = 20
        let offset = try XCTUnwrap(ScoreContext.utf8Offset(in: text, line: line, character: character + 4))
        XCTAssertEqual(ScoreGraphic.commandRange(at: offset, in: text).map { Array(text.utf8)[$0] }.map { String(decoding: $0, as: UTF8.self) },
                       "\\startGrains")

        let context = ScoreContext.describe(text: text, file: all[0].path, line: line, character: character, files: all)
        let graphic = try XCTUnwrap(context["graphic"])
        XCTAssertEqual(graphic["command"]?.string, "\\startGrains")
        XCTAssertEqual(graphic["stop"]?["line"]?.int, 293)
        XCTAssertEqual(graphic["stop"]?["command"]?.string, "\\stopGraphic")
        let def = try XCTUnwrap(graphic["definition"])
        XCTAssertEqual(def["text"]?.string, "\(def["from_line"]?.int ?? 0)| startGrains = #(graphic-span grains-stencil)")
        let drawing = try XCTUnwrap(graphic["drawing"]?.array?.first)
        XCTAssertEqual(drawing["name"]?.string, "grains-stencil")
        XCTAssertTrue(drawing["text"]?.string?.contains("(grains-at rs x0 w 0.05") ?? false)
        // Helpers the drawing calls come in full, numbered as in their file.
        let uses = graphic["uses"]?.array ?? []
        let grainsAt = try XCTUnwrap(uses.first { $0["name"]?.string == "grains-at" }, "\(uses)")
        XCTAssertEqual(grainsAt["file"]?.string, "graphics.ily")
        let from = try XCTUnwrap(grainsAt["from_line"]?.int)
        XCTAssertTrue(grainsAt["text"]?.string?.hasPrefix("\(from)| #(define") ?? false, "\(grainsAt)")
        XCTAssertTrue(uses.contains { $0["name"]?.string == "band-gathered" || ($0.string?.hasPrefix("band-gathered ") ?? false) }, "\(uses)")
        XCTAssertTrue(graphic["notes"]?.string?.contains("grains over the whole staff") ?? false)

        // The skip it is on starts at bar 4: 54 + 2 + 8 quarters in.
        XCTAssertEqual(context["event"]?["text"]?.string, "s4*2")
        XCTAssertEqual(context["moment"]?.string, "16")
        XCTAssertEqual(context["staff"]?.string, "electronicsGraphics")
    }

    func testALexiconGraphicIsStillDescribedByItsEntry() {
        let text = "elec = { s1\\startGraphic \"grain-cloud\" #'((density . 0.5)) s1 s1\\stopGraphic }\n"
        let context = ScoreContext.describe(text: text, file: "e.ly", line: 1, character: 11)
        XCTAssertEqual(context["graphic"]?["entry"]?.string, "grain-cloud")
        XCTAssertNil(context["graphic"]?["command"])
    }

    func testCuesAreListedForLaconicStops() throws {
        var log = TimingLog(rows: [])
        log.rows = [
            .init(moment: Rational(0), bar: 1, kind: .tempo(quartersPerMinute: 60)),
            .init(moment: Rational(9, 4), bar: 3, kind: .text("cue 7")),
        ]
        let sheet = CueSheet(log: log, score: "s.ly")
        let context = ScoreContext.describe(text: "m = { s1 s1 s1 }\n", file: "s.ly", line: 1, character: 6, cues: sheet)
        XCTAssertEqual(context["cues"]?.array?.first?.string, "7: bar 3, moment 9/4, 9 s")
    }

    func testStoppingAtACueSplitsTheSkipItFallsIn() throws {
        let score = "elec = { s4*5 \\mark \\default s4*7 | s4*7 }\n"
        // Moment 3/2 is 6 quarters in: 1 quarter into the s4*7.
        let new = try GraphicEdit.insert(into: score, id: "grain-cloud", params: "((density . (linear 0.1 1)))",
                                         start: (1, 9), stopMoment: Rational(3, 2))
        XCTAssertEqual(new, "elec = { s4*5\\startGraphic \"grain-cloud\" #'((density . (linear 0.1 1))) \\mark \\default s1*1/4 s1*3/2\\stopGraphic | s4*7 }\n")
        // On an event's own moment, no split.
        let exact = try GraphicEdit.insert(into: score, id: "wedge", params: "()", start: (1, 9), stopMoment: Rational(3))
        XCTAssertTrue(exact.hasSuffix("| s4*7\\stopGraphic }\n"), exact)
        // Inside the start's own skip: the start goes on its first part.
        let inside = try GraphicEdit.insert(into: score, id: "wedge", params: "()", start: (1, 9), stopMoment: Rational(1, 2))
        XCTAssertTrue(inside.hasPrefix("elec = { s1*1/2\\startGraphic \"wedge\" #'() s1*3/4\\stopGraphic \\mark"), inside)
        XCTAssertThrowsError(try GraphicEdit.insert(into: score, id: "wedge", params: "()", start: (1, 9), stopMoment: Rational(9)))
    }
}

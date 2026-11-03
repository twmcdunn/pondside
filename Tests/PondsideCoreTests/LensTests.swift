import Foundation
import XCTest
@testable import PondsideCore

final class LensTests: XCTestCase {
    private static let scores = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Scores")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.scores.appendingPathComponent(name), encoding: .utf8)
    }

    private func range(of needle: String, in text: String) throws -> Range<Int> {
        let range = try XCTUnwrap(text.range(of: needle))
        let start = text[..<range.lowerBound].utf8.count
        return start..<(start + needle.utf8.count)
    }

    private func lens(_ text: String, at needle: String) throws -> LensScoreWindow {
        try XCTUnwrap(LensScoreBuilder.build(tree: SyntaxTree(text), selection: try range(of: needle, in: text)))
    }

    private func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The `<measure>` holding the target, as text.
    private func targetMeasure(_ window: LensScoreWindow) throws -> String {
        let target = try XCTUnwrap(window.target)
        let measures = window.xml.components(separatedBy: "<measure ").dropFirst()
        return try XCTUnwrap(Array(measures)[safe: target.measureIndex])
    }

    func testInventionUpperAssignmentIsIsolated() throws {
        let text = try fixture("invention.ly")
        let window = try lens(text, at: "cis8 a'")
        XCTAssertEqual(window.label, "upper")
        XCTAssertTrue(window.xml.contains("<part-name>upper</part-name>"))
        XCTAssertTrue(window.unsupported.isEmpty, "\(window.unsupported)")
        // Measure 1 of 7: the window is it and the four after.
        XCTAssertEqual(count("<measure ", in: window.xml), 5)
        XCTAssertEqual(window.bars, 1...5)
        XCTAssertFalse(window.reachesEnd)
        let target = try XCTUnwrap(window.target)
        XCTAssertEqual(target.measureIndex, 0)
        XCTAssertEqual(target.ordinal, 8)
        // `\global` holds the key and meter.
        XCTAssertTrue(window.xml.contains("<fifths>-1</fifths><mode>minor</mode>"))
        XCTAssertTrue(window.xml.contains("<beats>4</beats><beat-type>4</beat-type>"))
    }

    func testInventionLowerTakesItsOwnClef() throws {
        let text = try fixture("invention.ly")
        let window = try lens(text, at: "c!4 bes8")
        XCTAssertEqual(window.label, "lower")
        XCTAssertTrue(window.xml.contains("<sign>F</sign><line>4</line>"))
        XCTAssertFalse(window.xml.contains("<sign>G</sign>"))
        XCTAssertEqual(window.target?.measureIndex, 2)
    }

    func testVoiceSplitBranchesShareTheirMeasure() throws {
        let text = try fixture("invention.ly")
        let window = try lens(text, at: "e d cis }")
        let target = try XCTUnwrap(window.target)
        XCTAssertEqual(target.voiceIndex, 1)
        XCTAssertEqual(target.ordinal, 1)
        // Bar 6 of the invention; both voices in it, the lower after a backup.
        let upper = try XCTUnwrap(window.events.first { $0.voiceIndex == 0 && $0.measureIndex == target.measureIndex })
        XCTAssertEqual(upper.ordinal, 0)
        let measure = try targetMeasure(window)
        XCTAssertTrue(measure.contains("<backup><duration>\(LensScoreBuilder.divisions * 4)</duration></backup>"))
        XCTAssertTrue(measure.contains("<voice>2</voice>"))
        XCTAssertTrue(measure.contains("<accidental>sharp</accidental>"))
    }

    func testQuartetSelectionIsIsolated() throws {
        let text = try fixture("quartet.ly")
        let window = try lens(text, at: "cs4 |")
        XCTAssertEqual(window.label, "violinII")
        XCTAssertTrue(window.xml.contains("<sign>G</sign><line>2</line>"))
        XCTAssertTrue(window.xml.contains("<beats>3</beats><beat-type>4</beat-type>"))
        XCTAssertTrue(window.xml.contains("<fifths>-2</fifths>"))
        // `\fixed c'`: cs4 is C♯4.
        let measure = try targetMeasure(window)
        XCTAssertTrue(measure.contains("<step>C</step><alter>1</alter><octave>4</octave>"))
        // `R2.*2` is two whole-bar rests.
        XCTAssertEqual(count("<rest measure=\"yes\"/>", in: window.xml), 2)

        let viola = try lens(text, at: "fs4->")
        XCTAssertEqual(viola.label, "viola")
        XCTAssertTrue(viola.xml.contains("<sign>C</sign><line>3</line>"))
        XCTAssertTrue(viola.unsupported.contains("transpose"))
        XCTAssertTrue(try targetMeasure(viola).contains("<accent/>"))
    }

    func testFluteClefAndMetersFollowTheSource() throws {
        let text = try fixture("large-graphic/flute.ly")
        let window = try lens(text, at: "gis'4 ^( fis'4")
        XCTAssertEqual(window.label, "flute")
        let measure = try targetMeasure(window)
        // Bar 6 is in 6/4; the clef is the quoted "treble".
        XCTAssertTrue(measure.contains("<beats>6</beats><beat-type>4</beat-type>"))
        XCTAssertTrue(window.xml.contains("<sign>G</sign><line>2</line>"))
        XCTAssertTrue(measure.contains("<step>G</step><alter>1</alter><octave>4</octave>"))
        // Custom graphic commands are named on a badge, not drawn.
        XCTAssertTrue(window.unsupported.contains { $0.hasPrefix("graphic:") && $0.contains("\\wind") })
    }

    func testMeasuresPitchesAndDurations() throws {
        let window = try lens("""
        upper = {
          \\time 4/4
          c'4 d e f |
          g a b c |
        }
        """, at: "g a")
        XCTAssertEqual(window.label, "upper")
        XCTAssertEqual(count("<measure ", in: window.xml), 2)
        XCTAssertEqual(window.target?.measureIndex, 1)
        XCTAssertEqual(window.target?.ordinal, 0)
        XCTAssertTrue(window.xml.contains("<step>G</step><octave>3</octave></pitch><duration>10080</duration>"))
        XCTAssertEqual(count("<type>quarter</type>", in: window.xml), 8)
    }

    func testNestedTupletChordDotsAndGraces() throws {
        let window = try lens("""
        upper = \\relative c' {
          \\tuplet 3/2 { c8 \\tuplet 3/2 { d16 e f } g8 } <f a>4. r4 r8 |
          \\grace e16 a4 \\times 2/3 { b8 c d } r2 |
        }
        """, at: "<f a>4.")
        XCTAssertTrue(window.xml.contains("<actual-notes>9</actual-notes><normal-notes>4</normal-notes>"))
        // Both chord tones are notes, and the chord is one event.
        XCTAssertEqual(count("<chord/>", in: window.xml), 1)
        XCTAssertEqual(window.target?.notes.count, 2)
        XCTAssertTrue(window.xml.contains("<dot/>"))
        // A grace has no duration and does not count as an element.
        XCTAssertTrue(window.xml.contains("<grace/><pitch><step>E</step><octave>4</octave></pitch><voice>"))
        let afterGrace = try XCTUnwrap(window.events.first { $0.measureIndex == 1 && !$0.isGrace })
        XCTAssertEqual(afterGrace.ordinal, 0)
        // `\times 2/3` is three in the time of two.
        XCTAssertTrue(window.xml.contains("<actual-notes>3</actual-notes><normal-notes>2</normal-notes>"))
    }

    func testPickupTiesAndAccidentals() throws {
        let window = try lens("""
        m = \\relative c'' {
          \\time 3/4 \\partial 4 fis4 |
          f2 fis4~ | fis4 f fis |
        }
        """, at: "f fis |")
        XCTAssertTrue(window.xml.contains("<measure number=\"0\" implicit=\"yes\">"))
        XCTAssertTrue(window.xml.contains("<measure number=\"2\">"))
        XCTAssertEqual(window.bars, 0...2)
        XCTAssertTrue(window.reachesEnd)
        let measure = try targetMeasure(window)
        // The tied F♯ needs no sign; the F after it needs a natural, the F♯ a sharp again.
        XCTAssertTrue(measure.hasPrefix("number=\"2\""))
        XCTAssertTrue(measure.contains("<tie type=\"stop\"/>"))
        XCTAssertEqual(count("<accidental>natural</accidental>", in: measure), 1)
        XCTAssertEqual(count("<accidental>sharp</accidental>", in: measure), 1)
    }

    func testInlineStavesInAScoreBlockAreSeparate() throws {
        let window = try lens("""
        \\score {
          << \\new Staff { c'4 d' e' f' } \\new Staff { \\clef bass g4 a b c' } >>
        }
        """, at: "a b")
        XCTAssertNil(window.label)
        XCTAssertTrue(window.xml.contains("<sign>F</sign>"))
        XCTAssertFalse(window.xml.contains("<step>D</step>"))
    }

    func testUnsupportedCommandsAreReported() throws {
        let window = try lens("""
        upper = {
          \\repeat volta 2 { c'4 d e f }
          g4^\\markup { \\bold "graphic" } a b cih |
          \\myGraphic c1
        }
        """, at: "g4")
        XCTAssertTrue(window.unsupported.contains("repeat"))
        XCTAssertTrue(window.unsupported.contains("markup"))
        XCTAssertTrue(window.unsupported.contains("quarter tones"))
        XCTAssertTrue(window.unsupported.contains("graphic: \\myGraphic"))
        XCTAssertFalse(window.unsupported.contains { $0.contains("bold") })
    }

    func testSlursPairWithinTheirVoice() throws {
        let window = try lens("""
        m = \\relative c'' {
          a4( b) c( d) | e^( f \\( g a\\) | b) << { c4( d) } \\\\ { e,( f) } >> g2 |
        }
        """, at: "e^(")
        let pairs = window.slurs.map { (window.events[$0.start].sourceEvent, window.events[$0.end].sourceEvent, $0.phrasing) }
        // a–b, c–d, e–b across a bar, the phrasing slur f–a (`\(` follows f), and one slur in each voice.
        XCTAssertEqual(pairs.count, 6, "\(pairs)")
        XCTAssertEqual(pairs.filter { $0.2 }.map { $0.1 - $0.0 }, [2])
        XCTAssertTrue(pairs.contains { $0.0 == 4 && $0.1 == 8 && !$0.2 })
        let voiced = window.slurs.filter { window.events[$0.start].voiceIndex != window.events[$0.end].voiceIndex }
        XCTAssertTrue(voiced.isEmpty)
        XCTAssertEqual(Set(window.slurs.map { window.events[$0.start].voiceIndex }), [0, 1])
    }

    func testTremolosTakeTheirWholeLength() throws {
        let window = try lens("""
        m = {
          \\time 4/4 \\repeat tremolo 16 { gis''32 ^( e''32 ) } |
          \\repeat tremolo 4 c''16 d''2. | e''1 |
        }
        """, at: "d''2.")
        // A whole-note pair fills bar 1; the one-note tremolo is a quarter.
        XCTAssertEqual(window.bars, 1...3)
        XCTAssertEqual(window.target?.measureIndex, 1)
        let first = try XCTUnwrap(window.xml.components(separatedBy: "<measure ").dropFirst().first)
        XCTAssertEqual(count("<type>whole</type>", in: first), 2)
        XCTAssertEqual(count("<actual-notes>2</actual-notes><normal-notes>1</normal-notes>", in: first), 2)
        XCTAssertEqual(window.tremolos.map(\.bars), [3, 2])
        XCTAssertEqual(window.tremolos.map(\.between), [true, false])
        XCTAssertEqual(window.events[window.tremolos[1].event].measureIndex, 1)
        XCTAssertTrue(try targetMeasure(window).contains("<type>quarter</type>"))
        XCTAssertFalse(window.unsupported.contains("repeat"))
    }

    func testTupletSpansForTheRenderer() throws {
        let window = try lens("""
        m = {
          \\time 2/4 \\tuplet 5/4 { c''16 d'' e'' f'' g'' } \\tuplet 3/2 { a''8 \\grace b''16 c'''8 d'''8 } |
          \\tuplet 6/4 { e''16 f'' g'' a'' b'' c''' } r4 |
        }
        """, at: "a''8")
        let spans = window.tuplets.map { ($0.end - $0.start, $0.actualNotes, $0.normalNotes) }
        // The grace sits inside the triplet's span but isn't one of its ends.
        XCTAssertEqual(spans.map(\.0), [4, 3, 5])
        XCTAssertEqual(spans.map(\.1), [5, 3, 6])
        XCTAssertEqual(spans.map(\.2), [4, 2, 4])
        XCTAssertEqual(window.bars, 1...2)
    }

    func testArrowStepsWalkTheTargetsVoice() throws {
        let text = """
        m = \\relative c'' {
          a4 \\grace b16 c4 << { d4 e } \\\\ { f,4 g } >> a'2 |
        }
        """
        let tree = SyntaxTree(text)
        func source(_ event: Int?) -> String? {
            event.map { String(decoding: Array(text.utf8)[tree.events[$0].range], as: UTF8.self) }
        }
        // The grace is stepped over.
        XCTAssertEqual(source(try lens(text, at: "a4").neighbor(1)), "c4")
        // The upper voice continues past the lower one.
        XCTAssertEqual(source(try lens(text, at: "e }").neighbor(1)), "a'2")
        XCTAssertEqual(source(try lens(text, at: "g }").neighbor(-1)), "f,4")
        // Where a voice ends, the nearest event of any voice.
        XCTAssertEqual(source(try lens(text, at: "f,4").neighbor(-1)), "e")
        XCTAssertNil(try lens(text, at: "a'2").neighbor(1))
        XCTAssertNil(try lens(text, at: "a4").neighbor(-1))
    }

    func testRangeSelectionKeepsEveryEvent() throws {
        let text = "m = \\relative c'' { c4 d4 e4 f4 }\n"
        let start = try range(of: "c4", in: text).lowerBound
        let end = try range(of: "e4", in: text).upperBound
        let window = try XCTUnwrap(LensScoreBuilder.build(tree: SyntaxTree(text), selection: start..<end))
        let marked = window.events.filter { window.selected.contains($0.sourceEvent) }
        XCTAssertEqual(marked.count, 3)
        XCTAssertEqual(window.selected.count, 3)
        XCTAssertEqual(window.target?.sourceEvent, marked.first?.sourceEvent)
    }

    func testCaretOutsideMusicHasNoLens() {
        let text = "\\header { title = \"x\" }\nm = { c'4 }\n"
        XCTAssertNil(LensScoreBuilder.build(tree: SyntaxTree(text), selection: 3..<3))
    }
}

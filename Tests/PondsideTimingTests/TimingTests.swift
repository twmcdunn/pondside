import XCTest
@testable import PondsideTiming

final class RationalTests: XCTestCase {
    func testParsingAndArithmetic() {
        XCTAssertEqual(Rational(parsing: "217/4"), Rational(217, 4))
        XCTAssertEqual(Rational(parsing: "6/8"), Rational(3, 4))
        XCTAssertEqual(Rational(parsing: "3"), Rational(3))
        XCTAssertEqual(Rational(parsing: "-1/8")?.description, "-1/8")
        XCTAssertNil(Rational(parsing: "1/0"))
        XCTAssertNil(Rational(parsing: "x"))
        XCTAssertEqual(Rational(1, 4) + Rational(1, 6), Rational(5, 12))
        XCTAssertEqual(Rational(3, 4) - Rational(1, 4), Rational(1, 2))
        XCTAssertEqual(Rational(3, 4) / Rational(1, 8), Rational(6))
        XCTAssertTrue(Rational(1, 3) < Rational(1, 2))
        XCTAssertEqual(Rational(2, -4).description, "-1/2")
    }
}

final class TempoMapTests: XCTestCase {
    func testDefaultIsLilyPondsMIDITempo() {
        let map = TempoMap(tempos: [])
        XCTAssertEqual(map.seconds(at: Rational(1)), 4)
        XCTAssertEqual(map.tempo(at: Rational(5)), 60)
    }

    func testStepsAccumulate() {
        // 4 = 120 from the start, 4 = 60 from the second bar of 4/4.
        let map = TempoMap(tempos: [(Rational(0), 120), (Rational(1), 60)])
        XCTAssertEqual(map.steps.count, 2, "a tempo at 0 replaces the default")
        XCTAssertEqual(map.seconds(at: Rational(1, 2)), 1, accuracy: 1e-12)
        XCTAssertEqual(map.seconds(at: Rational(1)), 2, accuracy: 1e-12)
        XCTAssertEqual(map.seconds(at: Rational(2)), 6, accuracy: 1e-12)
        XCTAssertEqual(map.moment(atSeconds: 4), 1.5, accuracy: 1e-12)
        XCTAssertEqual(map.moment(atSeconds: 1), 0.5, accuracy: 1e-12)
    }

    /// A fermata as the skill notates it: a whole-note hold at 60 lasts 4 s,
    /// then the tempo comes back.
    func testHiddenTempoHolds() {
        let map = TempoMap(tempos: [(Rational(0), 90), (Rational(2), 60), (Rational(3), 90)])
        let before = map.seconds(at: Rational(2))
        XCTAssertEqual(map.seconds(at: Rational(3)) - before, 4, accuracy: 1e-12)
    }

    func testConflictingTemposAtOneMomentAreReported() {
        let log = TimingLog(parsing: "0\t1\ttempo\t60\n1\t2\ttempo\t72\n1\t2\ttempo\t40\n1\t2\ttempo\t40\n")
        let map = TempoMap(log)
        XCTAssertEqual(map.conflicts, [Rational(1)])
        XCTAssertEqual(map.tempo(at: Rational(1)), 40)
    }
}

final class TimingLogTests: XCTestCase {
    /// timing.ily's format, as an existing piece's score.timing has it.
    static let legacy = """
    0\t1\ttempo\t72.0
    0\t1\ttext\tcue 1
    0\t1\ttext\tcue 1
    0\t1\tnote\telecUp\t60
    0\t1\tgroup\telecUp\tstart
    0\t1\tnote\telecUp\t64
    1/8\t1\tnote\telecUp\t67
    1/8\t1\tgroup\telecUp\tstop
    3/4\t2\ttext\timprov 1
    9/4\t3\ttext\tcue 2
    5/2\t3\ttext\tend
    some LilyPond chatter

    """

    func testReadsTimingIlyLogs() {
        let log = TimingLog(parsing: Self.legacy)
        XCTAssertEqual(log.rows.count, 11)
        XCTAssertEqual(log.texts(startingWith: "cue ").map(\.text), ["cue 1", "cue 2"], "one row per voice is deduplicated")
        XCTAssertEqual(log.end, Rational(5, 2))
        let ec = log.collections(staff: "elecUp")
        XCTAssertEqual(ec.count, 1)
        XCTAssertEqual(ec.first?.midi, [60, 64, 67])
    }

    func testReadsPondsideRowsWithPositions() {
        let log = TimingLog(parsing: "noise PONDSIDE-TIMING\t0\t1\t@0\tmeter\t6/8\nPONDSIDE-TIMING\t3/8\t1\t@3/8\ttext\tcue A\n",
                            prefix: "PONDSIDE-TIMING\t")
        XCTAssertEqual(log.rows.count, 2)
        XCTAssertEqual(log.meter(at: Rational(1))?.numerator, 6)
        XCTAssertEqual(log.meter(at: Rational(1))?.denominator, 8)
        XCTAssertEqual(log.rows[1].measurePosition, Rational(3, 8))
    }
}

final class CueSheetTests: XCTestCase {
    func testCueTimesMatchTheExistingExport() throws {
        let sheet = CueSheet(log: TimingLog(parsing: TimingLogTests.legacy), score: "score.ly", sampleRate: 48000)
        XCTAssertEqual(sheet.cues.map(\.name), ["1", "2"])
        // 9/4 whole notes = 9 quarters at 72 = 7.5 s.
        XCTAssertEqual(sheet.cues[1].seconds, 7.5, accuracy: 1e-9)
        XCTAssertEqual(sheet.cues[1].samples, 360_000)
        XCTAssertEqual(sheet.cuesText, "0.000\t1\tcue 1\n7.500\t3\tcue 2\n")
        XCTAssertEqual(sheet.duration ?? 0, 10.0 * 60 / 72, accuracy: 1e-9)
        XCTAssertEqual(sheet.marks.map(\.text), ["improv 1", "end"])
        XCTAssertNil(sheet.cues[0].position.beat, "timing.ily logs carry no bar position")
        XCTAssertEqual(sheet.cues.map(\.handler), ["cue1", "cue2"])
        let json = try XCTUnwrap(String(data: try sheet.json(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"schema\" : 1"))
    }

    func testBeatsAndStableIDs() {
        let text = """
        PONDSIDE-TIMING\t0\t1\t@0\tmeter\t3/4
        PONDSIDE-TIMING\t1/4\t1\t@1/4\ttext\tcue swell
        PONDSIDE-TIMING\t7/8\t2\t@1/8\ttext\tcue swell

        """
        let sheet = CueSheet(log: TimingLog(parsing: text, prefix: "PONDSIDE-TIMING\t"), score: "s.ly")
        XCTAssertEqual(sheet.cues.map(\.position.beat), [2, 1.5])
        XCTAssertEqual(sheet.cues.map(\.id), ["cue-swell", "cue-swell-2"])
        XCTAssertEqual(sheet.cues[0].handler, "swell")
        XCTAssertTrue(sheet.warnings.contains("cue swell appears 2 times"))
    }

    func testHandlerNames() {
        XCTAssertEqual(CueSheet.handlerName("12"), "cue12")
        XCTAssertEqual(CueSheet.handlerName("FxSwell"), "fxSwell")
        XCTAssertEqual(CueSheet.handlerName("fx swell"), "fx_swell")
    }
}

/// `pondside cues --format ec`: the `~ec` arrays patches have always
/// loaded from piece.ec.scd, from Pondside's own timing.
final class CollectionsTests: XCTestCase {
    func testCollectionsOnOneStaffWithTheirCue() {
        let log = TimingLog(rows: [
            .init(moment: Rational(0), bar: 1, kind: .tempo(quartersPerMinute: 60)),
            .init(moment: Rational(0), bar: 1, kind: .text("cue 1")),
            .init(moment: Rational(1), bar: 2, kind: .group(staff: "elecUp", start: true)),
            .init(moment: Rational(1), bar: 2, kind: .note(staff: "elecUp", midi: 62)),
            .init(moment: Rational(1), bar: 2, kind: .note(staff: "elecUp", midi: 60)),
            .init(moment: Rational(1), bar: 2, kind: .note(staff: "flute", midi: 79)),
            .init(moment: Rational(1), bar: 2, kind: .note(staff: "elecUp", midi: 74)),
            .init(moment: Rational(1), bar: 2, kind: .group(staff: "elecUp", start: false)),
        ])
        let found = Collections.find(in: log, staff: "elecUp")
        XCTAssertEqual(found.map(\.midi), [[62, 60, 74]])
        XCTAssertEqual(found.first?.pitchClasses, [0, 2])
        XCTAssertEqual(Collections.scd(found, staff: "elecUp", score: "s.ly"), """
        // Collections on staff elecUp, from s.ly (pondside cues --format ec):
        // pitch classes ascending from C; each line: index: bar, time, last cue: the notes as written.
        ~ec = [
        \t[0, 2]    // 0: bar 2, 4.0 s, cue 1: D C D
        ];
        // where each one is in the score (seconds at the render's tempo; cue: the last cue
        // at or before it), e.g. to check that the patch plays it in that cue's window
        ~ecWhere = [
        \t(bar: 2, time: 4.000, cue: "cue 1")
        ];

        """)
    }
}

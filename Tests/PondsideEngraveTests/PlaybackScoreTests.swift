import Foundation
import XCTest
import PondsideCore
import PondsideTiming
@testable import PondsideEngrave

/// The playback Pondside generates for a score without `\midi`: what the
/// mockup plays and cue times are computed from (one compile, one music).
/// The timing rows' notes are the played notes, so they show the expansion.
final class PlaybackScoreTests: XCTestCase {
    private func lilypond() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return lily
    }

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-playback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func play(_ music: String, staff: String = "") async throws -> PlaybackScore.Result {
        let lily = try await lilypond()
        let dir = try temp()
        let file = dir.appendingPathComponent("score.ly")
        try """
        \\version "2.24.0"
        ecue = #(define-event-function (label) (string?)
          (let ((ev #{ -\\tweak stencil ##f ^\\markup #label #})) (ly:music-set-property! ev 'cue-label label) ev))
        % as large-graphic's \\accTrill and \\shapedTrill mark their trills
        trillWith = #(define-event-function (sign) (string?)
          (let ((ev #{ \\trill #})) (ly:music-set-property! ev 'trill-upper sign) ev))
        shaped = #(define-event-function (speeds) (list?)
          (let ((ev #{ \\startTrillSpan #})) (ly:music-set-property! ev 'trill-shape speeds) ev))
        \\score { << \\new Staff = "a" \\relative c'' { \\tempo 4 = 60 \(music) } \(staff) >> \\layout { } }

        """.write(to: file, atomically: true, encoding: .utf8)
        return try await PlaybackScore.compile(lily, source: file, midi: dir.appendingPathComponent("out.midi"))
    }

    /// (onset in quarter notes, MIDI pitch) of every played note on `staff`.
    private func notes(_ r: PlaybackScore.Result, staff: String = "a") -> [(Double, Int)] {
        r.timing.rows.compactMap { row in
            guard case let .note(s, midi) = row.kind, s == staff else { return nil }
            return (Double(row.moment.numerator) / Double(row.moment.denominator) * 4, midi)
        }
    }

    func testAScoreWithoutMIDIGetsPlayback() async throws {
        let r = try await play("c4 d e f")
        XCTAssertTrue(r.generated)
        XCTAssertNotNil(r.midi)
        XCTAssertEqual(notes(r).map(\.1), [72, 74, 76, 77])
    }

    func testTheScoresOwnMIDIWins() async throws {
        let lily = try await lilypond()
        let dir = try temp()
        let file = dir.appendingPathComponent("score.ly")
        try "\\score { \\new Staff = \"a\" { \\repeat volta 2 { c'4 d' } } \\layout { } \\midi { } }\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let r = try await PlaybackScore.compile(lily, source: file, midi: dir.appendingPathComponent("out.midi"))
        XCTAssertFalse(r.generated)
        XCTAssertNotNil(r.midi)
        XCTAssertEqual(notes(r).map(\.1), [60, 62], "played as written: the repeat is not unfolded")
    }

    func testRepeatsAndTremolosArePlayedOut() async throws {
        let r = try await play("\\repeat volta 2 { c4 d } \\repeat tremolo 4 { c16 e } d2:16")
        let n = notes(r)
        XCTAssertEqual(n.prefix(4).map(\.1), [72, 74, 72, 74])
        XCTAssertEqual(n.dropFirst(4).prefix(8).map(\.1), [72, 76, 72, 76, 72, 76, 72, 76])
        XCTAssertEqual(n.dropFirst(4).prefix(8).map(\.0), [4, 4.25, 4.5, 4.75, 5, 5.25, 5.5, 5.75])
        XCTAssertEqual(n.dropFirst(12).map(\.1), Array(repeating: 74, count: 8))
        XCTAssertEqual(n.last?.0, 7.75)
    }

    func testTrillsAlternateWithTheUpperNoteOfTheKey() async throws {
        // G major: the trill on e alternates with f sharp, in 32nds.
        let r = try await play("\\key g \\major e4\\trill r")
        XCTAssertEqual(notes(r).map(\.1), [76, 78, 76, 78, 76, 78, 76, 78])
        XCTAssertEqual(notes(r).map(\.0), [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875])
    }

    func testTrillSpansPitchedTrillsAndSigns() async throws {
        // a span over a tie keeps alternating; \pitchedTrill names the upper note;
        // trill-upper (as \accTrill sets it) alters the upper step
        let r = try await play("""
        b2\\startTrillSpan ~ b4 r\\stopTrillSpan
        \\pitchedTrill g4\\startTrillSpan as r\\stopTrillSpan
        a4\\trillWith "♯"
        """)
        let n = notes(r)
        let span = n.filter { $0.0 < 3 }
        XCTAssertEqual(span.count, 24)
        XCTAssertEqual(Set(span.map(\.1)), [71, 72])
        XCTAssertEqual(span.map(\.1), (0..<24).map { $0 % 2 == 0 ? 71 : 72 })
        XCTAssertEqual(Set(n.filter { $0.0 >= 4 && $0.0 < 5 }.map(\.1)), [67, 68])
        XCTAssertEqual(Set(n.filter { $0.0 >= 6 }.map(\.1)), [69, 72], "a ♯ trill on a goes to b sharp")
    }

    func testShapedTrillsFollowTheirSpeeds() async throws {
        // \shapedTrill's data (large-graphic/defs.ily): speeds along the note
        let r = try await play("""
        c1\\shaped #'(0 1 0) r4\\stopTrillSpan
        """)
        let onsets = notes(r).map(\.0)
        let gaps = zip(onsets.dropFirst(), onsets).map { $0 - $1 }
        XCTAssertGreaterThan(gaps.first ?? 0, gaps[gaps.count / 2], "slow at the start, fast in the middle")
        XCTAssertGreaterThan(gaps.last ?? 0, gaps[gaps.count / 2], "and slow again at the end")
    }

    func testPrintedOnlyMusicIsSilentButKeepsItsTime() async throws {
        let r = try await play("\\tag #'printed { c1 } d4\\ecue \"1\"")
        XCTAssertEqual(notes(r).map(\.1), [74])
        XCTAssertEqual(notes(r).first?.0, 4)
        XCTAssertEqual(CueSheet(log: r.timing, score: "score.ly").cues.map(\.seconds), [4])
    }

    func testElectronicsStavesAreSilentButKeepTheirCues() async throws {
        let r = try await play("c1 c", staff: """
        \\new Staff = "e" \\with { instrumentName = "Electronics" } { s1 c'1\\ecue "2" }
        """)
        XCTAssertTrue(notes(r, staff: "e").isEmpty)
        XCTAssertEqual(CueSheet(log: r.timing, score: "score.ly").cues.map(\.seconds), [4])
    }

    func testDetectsTheScoresOwnMIDI() {
        XCTAssertTrue(EngravingSettingsDocument.writesMIDI("\\score { { c4 } \\layout { } \\midi { } }"))
        XCTAssertFalse(EngravingSettingsDocument.writesMIDI("\\score { { c4 } \\layout { } } % \\midi { }"))
        XCTAssertFalse(EngravingSettingsDocument.writesMIDI("\\midi { \\tempo 4 = 60 }\n\\score { { c4 } }"))
    }

    /// large-graphic's hand-written MIDI score (\\unfoldRepeats \\midiTrills
    /// \\removeWithTag #'printed, dynamics per staff) is the oracle: playback
    /// generated from its printed score alone plays the same notes.
    func testLargeGraphicMatchesItsHandWrittenMIDI() async throws {
        let lily = try await lilypond()
        let scores = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scores/large-graphic")
        let dir = try temp().appendingPathComponent("large-graphic")
        try FileManager.default.copyItem(at: scores, to: dir)
        let score = try String(contentsOf: dir.appendingPathComponent("score.ly"), encoding: .utf8)
        let cut = try XCTUnwrap(score.range(of: "% The MIDI for the audio render"))
        let printed = dir.appendingPathComponent("printed.ly")
        try String(score[..<cut.lowerBound]).write(to: printed, atomically: true, encoding: .utf8)

        let generated = try await PlaybackScore.compile(lily, source: printed, midi: dir.appendingPathComponent("generated.midi"))
        XCTAssertTrue(generated.generated)
        let hand = try await PlaybackScore.compile(lily, source: dir.appendingPathComponent("score.ly"),
                                                   midi: dir.appendingPathComponent("hand.midi"))
        XCTAssertFalse(hand.generated)
        let g = try Self.noteOns(Data(contentsOf: XCTUnwrap(generated.midi)))
        let h = try Self.noteOns(Data(contentsOf: XCTUnwrap(hand.midi)))
        XCTAssertGreaterThan(h.count, 400)
        XCTAssertEqual(g.count, h.count)
        XCTAssertEqual(g.map(\.1), h.map(\.1))
        XCTAssertEqual(g.map(\.0), h.map(\.0))
    }

    /// (tick, pitch) of every note-on in a MIDI file, sorted.
    static func noteOns(_ data: Data) -> [(Int, Int)] {
        let b = [UInt8](data)
        var out: [(Int, Int)] = []
        var i = 14
        while i + 8 <= b.count {
            guard b[i..<i + 4].elementsEqual("MTrk".utf8) else { break }
            let n = b[i + 4..<i + 8].reduce(0) { $0 << 8 | Int($1) }
            var j = i + 8, tick = 0, status: UInt8 = 0
            let end = i + 8 + n
            while j < end {
                var v = 0
                while true { let c = b[j]; j += 1; v = v << 7 | Int(c & 0x7f); if c < 0x80 { break } }
                tick += v
                if b[j] == 0xff { j += 3 + Int(b[j + 2]); continue }
                if b[j] & 0x80 != 0 { status = b[j]; j += 1 }
                switch status & 0xf0 {
                case 0xc0, 0xd0: j += 1
                default:
                    if status & 0xf0 == 0x90, b[j + 1] > 0 { out.append((tick, Int(b[j]))) }
                    j += 2
                }
            }
            i = end
        }
        return out.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }
}

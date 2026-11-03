import Foundation
import XCTest
import PondsideCore
import PondsideTiming
@testable import PondsideEngrave

/// M8: cue times come from LilyPond's own interpretation of the score.
final class TimingDumpTests: XCTestCase {
    func testCueTimesFromARealScore() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        // \ecue as electronics.ily defines it: a hidden text carrying cue-label.
        let source = """
        \\version "2.24.0"
        ecue = #(define-event-function (label) (string?)
          (let ((ev #{ -\\tweak stencil ##f ^\\markup #label #}))
            (ly:music-set-property! ev 'cue-label label)
            ev))
        \\score {
          \\new Staff = "fl" \\relative c'' {
            \\time 3/4 \\tempo 4 = 120
            c4 d e\\ecue "1" |
            \\tempo 2 = 30 f2. |
            g4 a b\\ecue "2" | \\bar "|."
          }
          \\layout { }
        }

        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-timing-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cues.ly")
        try source.write(to: file, atomically: true, encoding: .utf8)

        let log = try await TimingDump.run(lily, source: file)
        // Every note from the score says where it was written: the playback
        // head needs that to find the glyph on the page.
        let notes = log.rows.filter { if case .note = $0.kind { return true } else { return false } }
        XCTAssertFalse(notes.isEmpty)
        XCTAssertTrue(notes.allSatisfy { $0.origin != nil }, "\(notes)")
        XCTAssertTrue(notes.allSatisfy { $0.origin?.file.hasSuffix("cues.ly") == true })
        let sheet = CueSheet(log: log, score: "cues.ly", sampleRate: 48000)
        XCTAssertEqual(sheet.cues.map(\.name), ["1", "2"])
        // Two quarters at 120 = 1 s; then bar 1's last beat (0.5 s) and
        // five quarters at 2 = 30 (60 quarters a minute) = 5 s.
        XCTAssertEqual(sheet.cues.map(\.seconds), [1.0, 6.5])
        XCTAssertEqual(sheet.cues.map(\.position.measure), [1, 3])
        XCTAssertEqual(sheet.cues.map(\.position.beat), [3, 3])
        XCTAssertEqual(sheet.cues.map(\.position.moment), ["1/2", "2"])
        XCTAssertEqual(sheet.tempo.map(\.bpm), [120, 60])
        XCTAssertTrue(sheet.warnings.isEmpty, "\(sheet.warnings)")
        // Each cue knows where it is written (the \ecue itself).
        XCTAssertEqual(sheet.cues.map { $0.source?.line }, [9, 11])
        XCTAssertEqual(sheet.cues.map { $0.source?.character }, [10, 10])

        // A canvas compile logs the same timing for free.
        let dir2 = dir.appendingPathComponent("canvas")
        let canvas = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas, outputDirectory: dir2)
        XCTAssertEqual(CueSheet(log: canvas.timing, score: "cues.ly").cues.map(\.seconds), [1.0, 6.5])
        let canvasNotes = canvas.timing.rows.filter { if case .note = $0.kind { return true } else { return false } }
        XCTAssertTrue(canvasNotes.allSatisfy { $0.origin != nil }, "\(canvasNotes)")
        XCTAssertFalse(canvas.messages.contains("PONDSIDE-TIMING"))
    }
}

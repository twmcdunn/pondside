import XCTest
@testable import PondsideCore

final class PlaybackSourceSignatureTests: XCTestCase {
    func testLayoutOnlyEditsDoNotChangePlaybackSignature() {
        let source = "{ c'4 d'4 }"
        for changed in ["{ c'4 \\break d'4 }", "{ c'4 \\pageBreak d'4 }", "{ c'4 d'4 } % comment\n",
                        "\\header { title = \"New title\" } { c'4 d'4 }", "\\paper { paper-width = 100 } { c'4 d'4 }",
                        "{ \\omit Staff.TimeSignature c'4 \\revert Staff.TimeSignature.stencil d'4 }",
                        "{ \\override NoteHead.color = #red c'4 d'4 }"] {
            XCTAssertTrue(PlaybackSourceSignature.equivalent(source, changed), changed)
        }
    }

    func testMusicalAndOpaqueChangesRemainSignificant() {
        let source = "{ c'4 d'4 }"
        for changed in ["{ c'8 d'4 }", "{ cis'4 d'4 }", "{ c'4\\f d'4 }", "{ \\tempo 4 = 120 c'4 d'4 }",
                        "{ \\set Staff.midiInstrument = \"oboe\" c'4 d'4 }", "{ \\override NoteHead.color = #(change-sound) c'4 d'4 }"] {
            XCTAssertFalse(PlaybackSourceSignature.equivalent(source, changed), changed)
        }
    }
    func testAccidentalDisplayMarksDoNotChangeSound() {
        XCTAssertTrue(PlaybackSourceSignature.equivalent("{ cis'!4 cis'?4 c'!4 }", "{ cis'4 cis'4 c'4 }"))
        XCTAssertFalse(PlaybackSourceSignature.equivalent("{ cis'!4 }", "{ c'!4 }"))
    }
}

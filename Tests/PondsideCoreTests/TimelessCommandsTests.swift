import XCTest
@testable import PondsideCore

/// Custom commands that take no time, and Scheme that only sets values: a bar
/// using them is measured from source (unmetered entry, shared measures).
final class TimelessCommandsTests: XCTestCase {
    private let defs = #"""
    caes = {
      \once \override BreathingSign.text = \markup \musicglyph "scripts.caesura.straight"
      \once \override BreathingSign.extra-offset = #'(-1.6 . 0)
      \breathe
    }
    featherOnce = \once \override Beam.grow-direction = #RIGHT
    accelSpan = -\tweak bound-details.left.text \markup \italic "accel."
                -\tweak after-line-breaking #ly:spanner::kill-zero-spanned-time
                \startTextSpan

    #(define (helper x) x)
    wind =
    #(define-event-function (fraction) (number?)
       #{ ^\markup \wind-circle #fraction #})
    wrapped =
    #(define-event-function (music) (ly:music?)
       #{ -\markup "x" #})
    niente = #(make-dynamic-script (markup #:normal-text "n"))
    improvisation =
    #(define-music-function (n music) (index? ly:music?)
       #{ #music #})
    % pondside: no time
    accTrill =
    #(define-music-function (above) (string?)
       #{ -\markup #above #})
    % pondside: no time

    spaced =
    #(define-music-function () () #{ s4 #})
    caesTwice = { \caes \caes }
    pause = { \skip 4 }
    notes = { c4 d4 }
    usesPause = { \pause }
    twice = { \breathe }
    """#

    private let other = #"""
    twice = #(define-music-function () () #{ s4 #})
    """#

    private var names: Set<String> { TimelessCommands.names(in: [SyntaxTree(defs), SyntaxTree(other)]) }

    func testDefinitionsThatTakeNoTime() {
        let names = self.names
        for name in ["caes", "featherOnce", "accelSpan", "wind", "niente", "accTrill", "caesTwice"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testDefinitionsThatMayTakeTime() {
        let names = self.names
        // A music argument, a music function, the marker across a blank line,
        // a skip, notes, a command that takes time, two disagreeing definitions.
        for name in ["wrapped", "improvisation", "spaced", "pause", "notes", "usesPause", "twice", "helper"] {
            XCTAssertFalse(names.contains(name), name)
        }
    }

    private func measure(_ body: String) -> (SyntaxTree, Range<Int>) {
        let text = "\\pondsideMeasure \\pondsideBarA { \(body) }\n"
        let tree = SyntaxTree(text)
        let measure = StructuralEditing.measures(in: tree)[0]
        return (tree, measure.body)
    }

    func testTimelessCommandsDoNotNeedTheInterpreter() {
        let (tree, body) = measure(#"c4 \wind #1 d4 \timeField "x" "30″" e2 \caes"#)
        XCTAssertTrue(StructuralEditing.needsInterpreter(in: tree, body: body))
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: tree, body: body, timeless: ["wind", "timeField", "caes"]))
        let bar = StructuralEditing.measures(in: tree)[0]
        XCTAssertNil(StructuralEditing.contentMeter(in: tree, measure: bar))
        XCTAssertEqual(StructuralEditing.contentMeter(in: tree, measure: bar, timeless: ["wind", "timeField", "caes"]),
                       LensTime(beats: 1, beatType: 1))
    }

    func testCommandsThatMayTakeTimeStillNeedIt() {
        let (tree, body) = measure(#"\improvisation 1 { c4 d4 } \caes"#)
        XCTAssertTrue(StructuralEditing.needsInterpreter(in: tree, body: body, timeless: names))
    }

    func testValueSchemeIsNotGeneratedMusic() {
        let tweak = measure(#"e''16(\p -\tweak stencil #(elbowed-hairpin '((0 . 0) (1.0 . 1.0)) #t) \< fis''16)"#)
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: tweak.0, body: tweak.1))
        let override = measure(#"\once \override Beam.positions = #(cons 1 2) c8[ d8]"#)
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: override.0, body: override.1))
        let dynamic = measure(#"c4-#(make-dynamic-script "sfz") d4"#)
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: dynamic.0, body: dynamic.1))
    }

    func testMusicSchemeIsGeneratedMusic() {
        let made = measure(#"c4 #(make-music 'SkipMusic 'duration (ly:make-duration 2)) d4"#)
        XCTAssertTrue(StructuralEditing.needsInterpreter(in: made.0, body: made.1))
        let dollar = measure(#"c4 $(skip-of-length #{ c4 #}) d4"#)
        XCTAssertTrue(StructuralEditing.needsInterpreter(in: dollar.0, body: dollar.1))
        let simultaneous = measure(#"<< { c4 } \\ { d4 } >>"#)
        XCTAssertTrue(StructuralEditing.needsInterpreter(in: simultaneous.0, body: simultaneous.1))
    }

    func testMarkupArgumentsAreText() {
        let (tree, body) = measure(#"c4^\markup \concat { "on D" \hspace #0.15 \raise #0.4 \fontsize #-3 \flat } d4^\markup \fontsize #-3 \flat e2"#)
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: tree, body: body))
    }
}

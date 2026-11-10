import XCTest
@testable import PondsideCore

/// ⌥F fanned beams, ⌥H hidden notes, and the voices of skips and marks
/// (cues, collections) that follow a bar's new length in unmetered entry.
final class BeamingAndRescaleTests: XCTestCase {
    private func notes(_ tree: SyntaxTree) -> [Int] {
        tree.events.indices.filter { tree.events[$0].kind == .note }
    }

    /// Applies `edit`, checks its inverse restores the text and that its
    /// selection lands on events.
    private func applied(_ edit: ScoreEdit?, to text: String, line: UInt = #line) -> String {
        guard let edit else { XCTFail("no edit", line: line); return text }
        let result = edit.edits.apply(to: text)
        XCTAssertEqual(edit.edits.inverse(original: Array(text.utf8)).apply(to: result), text, line: line)
        let tree = SyntaxTree(result)
        XCTAssertEqual(tree.reconstructed, result, line: line)
        for anchor in edit.selectionAnchors {
            XCTAssertTrue(tree.events.contains { $0.range.lowerBound == anchor }, "anchor \(anchor)", line: line)
        }
        return result
    }

    func testFanBeamAddsOneBeamAndTogglesItsDirection() {
        let text = "{ c'16 d' e' f' }"
        let tree = SyntaxTree(text)
        let accel = applied(ScoreEditor(tree).fanBeam(.accelerando, events: notes(tree)), to: text)
        XCTAssertEqual(accel, "{ \\once \\override Beam.grow-direction = #RIGHT c'16[ d' e' f'] }")
        let fanned = SyntaxTree(accel)
        let rit = applied(ScoreEditor(fanned).fanBeam(.ritardando, events: notes(fanned)), to: accel)
        XCTAssertEqual(rit, "{ \\once \\override Beam.grow-direction = #LEFT c'16[ d' e' f'] }")
        let off = applied(ScoreEditor(fanned).fanBeam(.accelerando, events: notes(fanned)), to: accel)
        XCTAssertEqual(off, "{ c'16[ d' e' f'] }")
    }

    func testFanBeamReplacesTheBeamsInside() {
        let text = "{ c'16[ d'] e'[ f'] }"
        let tree = SyntaxTree(text)
        XCTAssertEqual(applied(ScoreEditor(tree).fanBeam(.accelerando, events: notes(tree)), to: text),
                       "{ \\once \\override Beam.grow-direction = #RIGHT c'16[ d' e' f'] }")
    }

    func testHideNotesTogglesAroundTheSelection() {
        let text = "{ c'4 d' e' f' }"
        let tree = SyntaxTree(text)
        let middle = Array(notes(tree)[1...2])
        let hidden = applied(ScoreEditor(tree).toggleHidden(events: middle), to: text)
        XCTAssertEqual(hidden, "{ c'4 \\hideNotes d' e' \\unHideNotes f' }")
        let again = SyntaxTree(hidden)
        XCTAssertEqual(applied(ScoreEditor(again).toggleHidden(events: Array(notes(again)[1...2])), to: hidden), text)
        // Hidden notes keep their time.
        XCTAssertFalse(StructuralEditing.needsInterpreter(in: again, body: 1..<(hidden.utf8.count - 1)))
    }

    // MARK: Rescaling

    private func file(_ id: String, _ text: String) -> StructuralEditing.File { .init(id: id, tree: SyntaxTree(text)) }

    private let ecue = "ecue = #(define-event-function (label) (string?) #{ ^\\markup #label #})\n"

    /// A managed two-voice score whose electronics bar is `electronics`.
    private func managed(flute: String, electronics: String) throws -> [StructuralEditing.File] {
        let files = [file("score.ly", "\\version \"2.24.3\"\n\\include \"part.ily\"\n\\score { << \\new Staff \\flute \\new Staff \\electronics >> }"),
                     file("part.ily", ecue + "flute = { \(flute) }\nelectronics = { s1 }")]
        var migrated = files
        for change in try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true) {
            let i = migrated.firstIndex { $0.id == change.file }!
            migrated[i] = file(change.file, change.edits.apply(to: migrated[i].tree.text))
        }
        let bars = StructuralEditing.measures(in: migrated[1].tree)
        migrated[1] = file("part.ily", [TextEdit(bars[1].body, electronics)].apply(to: migrated[1].tree.text))
        return migrated
    }

    /// The bar's meter and electronics body after replacing the flute's bar with `flute`.
    private func resize(_ files: [StructuralEditing.File], flute: String) throws -> (LensTime?, String) {
        let bar = StructuralEditing.measures(in: files[1].tree)[0]
        let proposed = SyntaxTree([TextEdit(bar.body, flute)].apply(to: files[1].tree.text))
        let changes = try StructuralEditing.resizingForContentChange(in: "part.ily", proposed: proposed, files: files, root: "score.ly")
        var after = files
        after[1].tree = proposed
        for change in changes {
            let i = after.firstIndex { $0.id == change.file }!
            XCTAssertTrue(change.edits.isNonOverlapping)
            after[i] = file(change.file, change.edits.apply(to: after[i].tree.text))
        }
        let electronics = StructuralEditing.measures(in: after[1].tree)[1]
        return (StructuralEditing.time(in: after[0].tree, name: "pondsideBarA"), after[1].tree.string(electronics.body))
    }

    func testShorterNotesShortenTheBarAndCuesStayWithTheirNotes() throws {
        let files = try managed(flute: " c'16 d' e' f' g' a' b' c'' c'4 c'4 ",
                                electronics: #" s4*0\ecue "1" s4 s4*0\ecue "2" s4 s2 "#)
        let (meter, electronics) = try resize(files, flute: " c'32 d' e' f' g' a' b' c'' c'4 c'4 ")
        XCTAssertEqual(meter, LensTime(beats: 3, beatType: 4))
        // Cue 2 was under g', the fifth sixteenth; it is under it still.
        XCTAssertEqual(electronics, #" s4*0\ecue "1" s4*1/2 s4*0\ecue "2" s4*1/2 s2 "#)
    }

    func testALongerBarSpreadsTheMarksPastTheMusic() throws {
        let files = try managed(flute: " c'4 d' e' f' ", electronics: #" s2 s4*0\ecue "1" s2 "#)
        let (meter, electronics) = try resize(files, flute: " c'4 d' e' f' g' ")
        XCTAssertEqual(meter, LensTime(beats: 5, beatType: 4))
        XCTAssertEqual(electronics, #" s2 s4*0\ecue "1" s2*3/2 "#)
    }

    func testAVoiceWithNotesKeepsTheBarLong() throws {
        let files = try managed(flute: " c'4 d' e' f' ", electronics: " d'1 ")
        let (meter, electronics) = try resize(files, flute: " c'8 d' e' f' ")
        XCTAssertEqual(meter, LensTime(beats: 4, beatType: 4))
        XCTAssertEqual(electronics, " d'1 ")
    }

    func testTheTimeMapIsPiecewiseLinear() {
        let map = StructuralEditing.BarTimeMap(points: [(.zero, .zero), (LensFraction(1, 2), LensFraction(1, 4)), (.one, LensFraction(3, 4))])
        XCTAssertEqual(map(LensFraction(1, 4)), LensFraction(1, 8))
        XCTAssertEqual(map(LensFraction(3, 4)), LensFraction(1, 2))
        XCTAssertEqual(map(.one), LensFraction(3, 4))
        XCTAssertEqual(StructuralEditing.durationText(DurationValue(log: 2, factorNumerator: 54), length: LensFraction(27, 4)), "4*27")
        XCTAssertEqual(StructuralEditing.durationText(DurationValue(log: 0), length: .zero), "1*0")
    }
}

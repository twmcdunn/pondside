import XCTest
@testable import PondsideCore

final class AccidentalTests: XCTestCase {
    func testEqualsFlatAndNaturalKeysArmAndToggle() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(KeyInput(.character("+")), now: 0), [])
        for (key, alteration) in [(Character("="), 2), ("-", -2), ("0", 0)] {
            XCTAssertEqual(input.handle(KeyInput(.character(key)), now: 1), [.toggleAccidental(alteration), .buffer("")])
            XCTAssertEqual(input.armedAccidental, alteration)
            _ = input.handle(KeyInput(.character(key)), now: 2)
            XCTAssertNil(input.armedAccidental)
        }
    }

    func testExplicitEntryForcesRedundantAccidental() throws {
        let tree = SyntaxTree("{ \\key g \\major fis'4 }")
        let edit = try XCTUnwrap(ScoreEditor(tree).insert(step: 3, after: 0, duration: .quarter, accidental: 2))
        let proposed = SyntaxTree(edit.edits.apply(to: tree.text))
        let inserted = try XCTUnwrap(proposed.eventIndex(at: edit.selectionAnchors[0]))
        XCTAssertNotNil(proposed.notes[proposed.events[inserted].notes[0]].accidentalMark)
        let lens = try XCTUnwrap(LensScoreBuilder.build(tree: proposed, selection: proposed.events[inserted].range))
        XCTAssertEqual(lens.xml.components(separatedBy: "<accidental>sharp</accidental>").count - 1, 1)
        XCTAssertTrue(lens.events.contains { $0.notes.contains(where: \.forcesAccidental) })
        XCTAssertEqual(proposed.reconstructed, proposed.text)
        XCTAssertTrue(edit.edits.isNonOverlapping)
    }

    func testKeyAndEarlierNoteRedundancyTogglesByteExactly() throws {
        for source in ["{ \\key g \\major fis'4 fis'4 }", "{ cis'4 cis'4 }"] {
            let tree = SyntaxTree(source)
            let last = tree.events.count - 1
            let show = try XCTUnwrap(ScoreEditor(tree).toggleAccidental(2, events: [last]))
            let forced = SyntaxTree(show.edits.apply(to: source))
            XCTAssertNotNil(forced.notes[forced.events[last].notes[0]].accidentalMark)
            let hide = try XCTUnwrap(ScoreEditor(forced).toggleAccidental(2, events: [last]))
            XCTAssertEqual(hide.edits.apply(to: forced.text), source)
        }
    }

    func testNonredundantGlyphRemovalRestoresInheritedPitch() throws {
        for (source, expected, alteration) in [("{ c'4 cis'4 }", "{ c'4 c'4 }", 2), ("{ cis'4 c'!4 }", "{ cis'4 cis'4 }", 0), ("{ ces'4 c'!4 }", "{ ces'4 ces'4 }", 0)] {
            let tree = SyntaxTree(source)
            let edit = try XCTUnwrap(ScoreEditor(tree).toggleAccidental(alteration, events: [1]))
            XCTAssertEqual(edit.edits.apply(to: source), expected)
            XCTAssertTrue(edit.edits.isNonOverlapping)
        }
    }

    func testForcedNaturalsAndChromaticMovement() throws {
        let tree = SyntaxTree("{ c'4 c'4 }")
        let edit = try XCTUnwrap(ScoreEditor(tree).toggleAccidental(0, events: [1]))
        let forced = SyntaxTree(edit.edits.apply(to: tree.text))
        XCTAssertTrue(forced.text.contains("c'!4"))
        let lens = try XCTUnwrap(LensScoreBuilder.build(tree: forced, selection: forced.events[1].range))
        XCTAssertTrue(lens.xml.contains("<accidental>natural</accidental>"))
        let move = try XCTUnwrap(ScoreEditor(forced).move(events: [1], by: .chromatic(1)))
        let automatic = SyntaxTree(move.edits.apply(to: forced.text))
        XCTAssertNil(automatic.notes[automatic.events[1].notes[0]].accidentalMark)
    }

    func testTogglingAForcedRangeHidesAllSelectedGlyphs() throws {
        let tree = SyntaxTree("{ cis'!4 cis'!4 }")
        let edit = try XCTUnwrap(ScoreEditor(tree).toggleAccidental(2, events: [0, 1]))
        let hidden = SyntaxTree(edit.edits.apply(to: tree.text))
        XCTAssertEqual(hidden.text, "{ c'4 c'4 }")
    }
    func testUnarmedEntryInheritsMeasureAccidentalsWithoutForcingGlyphs() throws {
        for (source, octave, expected) in [
            ("{ fis'4 g'4 }", 1, 2),
            ("{ fes'4 g'4 }", 1, -2),
            ("{ fis'4 f'4 g'4 }", 1, 0),
            ("{ fis'4 g'4 }", 2, 0),
            ("{ fis'1 | g'4 }", 1, 0),
            ("{ \\time 2/4 fis'4 g'4 }", 1, 0),
            ("{ \\key g \\major f'4 g'4 }", 1, 0),
            ("{ \\key g \\major c'4 }", 1, 2),
        ] {
            let tree = SyntaxTree(source)
            let edit = try XCTUnwrap(ScoreEditor(tree).insert(step: 3, after: tree.events.count - 1, duration: .quarter, octave: octave))
            let proposed = SyntaxTree(edit.edits.apply(to: source))
            let event = try XCTUnwrap(proposed.eventIndex(at: edit.selectionAnchors[0]))
            let note = proposed.notes[proposed.events[event].notes[0]]
            XCTAssertEqual(note.absolute.alteration, expected, source)
            XCTAssertNil(note.accidentalMark, source)
            XCTAssertEqual(proposed.reconstructed, proposed.text)
        }
    }

    func testUnarmedRepeatDoesNotEmitAnotherAccidentalInLens() throws {
        let tree = SyntaxTree("{ fis'!4 g'4 }")
        let edit = try XCTUnwrap(ScoreEditor(tree).insert(step: 3, after: 1, duration: .quarter))
        let proposed = SyntaxTree(edit.edits.apply(to: tree.text))
        let lens = try XCTUnwrap(LensScoreBuilder.build(tree: proposed, selection: edit.selectionAnchors[0]..<edit.selectionAnchors[0]))
        XCTAssertEqual(lens.xml.components(separatedBy: "<accidental>sharp</accidental>").count - 1, 1)
        XCTAssertFalse(lens.xml.contains("<accidental>natural</accidental>"))
    }

    func testManagedEntryInheritsWithinExtendedBarAndResetsAtNextWrapper() throws {
        let original = "\\score { \\new Staff { fis'1 | g'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(original))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: original).replacingOccurrences(of: "g'1", with: "s1*0"))
        let tree = files[0].tree
        let anchor = tree.events.firstIndex { !$0.notes.isEmpty }!
        let result = try UnmeteredInputPlan.prepare([.insert(step: 3, duration: .quarter, octave: 1, accidental: nil)], files: files, root: "score.ly", active: "score.ly", anchor: anchor)
        let event = try XCTUnwrap(result.files[0].tree.eventIndex(at: result.selection))
        let note = result.files[0].tree.notes[result.files[0].tree.events[event].notes[0]]
        XCTAssertEqual(note.absolute.alteration, 2)
        XCTAssertNil(note.accidentalMark)
        try StructuralEditing.verifyLengths(result.files, root: "score.ly")
        let next = StructuralEditing.measures(in: tree)[1]
        let edit = try XCTUnwrap(ScoreEditor(tree).insert(step: 3, after: anchor, duration: .quarter, insertionAt: next.body.lowerBound))
        let proposed = SyntaxTree(edit.edits.apply(to: tree.text))
        let inserted = try XCTUnwrap(proposed.eventIndex(at: edit.selectionAnchors[0]))
        XCTAssertEqual(proposed.notes[proposed.events[inserted].notes[0]].absolute.alteration, 0)
        XCTAssertNil(proposed.notes[proposed.events[inserted].notes[0]].accidentalMark)
    }
}

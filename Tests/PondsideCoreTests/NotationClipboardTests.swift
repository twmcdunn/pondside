import XCTest
@testable import PondsideCore

final class NotationClipboardTests: XCTestCase {
    func testCopiesAbsolutePitchesAndInheritedDurations() throws {
        let tree = SyntaxTree("\\relative c' { c8 d e f }")
        let copied = try XCTUnwrap(NotationClipboard.copy(tree: tree, events: [1, 2]))
        XCTAssertEqual(copied, "\\absolute { d'8 e'8 }")
    }

    func testCopiesChordsRestsTupletsAndBalancedSpans() throws {
        let tree = SyntaxTree("{ \\tuplet 3/2 { <c' e' g'>8( r8 d'8) } }")
        let copied = try XCTUnwrap(NotationClipboard.copy(tree: tree, events: Array(tree.events.indices)))
        XCTAssertTrue(copied.contains("\\tuplet 3/2 { <c' e' g'>8( r8 d'8) }"))
        let partial = try XCTUnwrap(NotationClipboard.copy(tree: tree, events: [2]))
        XCTAssertFalse(partial.contains(")"), "An external slur endpoint must not be pasted")
    }

    func testPastePreservesSurroundingNotesAndUndoIsByteExact() throws {
        let sources = ["\\relative c' { c8 d e f }", "\\fixed c'' { <c e g>4. r8 d2 }",
                       "{ \\tuplet 3/2 { c'8 d' e' } f'4 }", "\\language \"english\" { cs''4 bf'8 r8 }"]
        for source in sources {
            let tree = SyntaxTree(source)
            let copied = try XCTUnwrap(NotationClipboard.copy(tree: tree, events: Array(tree.events.indices)))
            let expected = SyntaxTree(copied)
            for destination in ["\\relative c'' { b4 c d }", "\\fixed c' { a4 b c }", "\\language \"deutsch\" { h'4 c'' d'' }"] {
                let before = SyntaxTree(destination)
                let edit = try XCTUnwrap(ScoreEditor(before).pasteNotation(copied, after: 0))
                let text = edit.edits.apply(to: destination)
                let after = SyntaxTree(text)
                XCTAssertEqual(after.events.count, before.events.count + expected.events.count)
                for index in before.events.indices {
                    let newIndex = index == 0 ? 0 : index + expected.events.count
                    XCTAssertEqual(after.events[newIndex].notes.map { after.notes[$0].absolute }, before.events[index].notes.map { before.notes[$0].absolute })
                    XCTAssertEqual(after.events[newIndex].effectiveDuration, before.events[index].effectiveDuration)
                }
                XCTAssertEqual(edit.edits.inverse(original: before.bytes).apply(to: text), destination)
            }
        }
    }

    func testPasteKeepsIncludedNoteNameLanguage() throws {
        let source = "{ cs'4 df'8 ef'8 }"
        let tree = SyntaxTree(source, language: .english)
        let edit = try XCTUnwrap(ScoreEditor(tree).pasteNotation("\\absolute { cis''8 }", after: 0,
            parsing: { SyntaxTree($0, language: .english) }))
        let after = SyntaxTree(edit.edits.apply(to: source), language: .english)
        XCTAssertEqual(after.events.count, 4)
        XCTAssertEqual(after.notes[1].absolute, Pitch(step: 0, alteration: 2, octave: 2))
        XCTAssertEqual(after.notes[2].absolute, tree.notes[1].absolute)
    }

    func testRejectsUnsupportedClipboardAndSelection() {
        let tree = SyntaxTree("{ c'4 d' }")
        XCTAssertNil(NotationClipboard.copy(tree: tree, events: []))
        XCTAssertNil(ScoreEditor(tree).pasteNotation("not music", after: 0))
    }

    func testRepeatInsertsSelectionAfterItselfAndSelectsTheCopy() throws {
        let source = "\\relative c' { c8 d e f g2 }"
        let tree = SyntaxTree(source)
        let edit = try XCTUnwrap(ScoreEditor(tree).repeatNotation(events: [1, 2]))
        XCTAssertEqual(edit.name, "Repeat Selection")
        let text = edit.edits.apply(to: source)
        let after = SyntaxTree(text)
        let pitches = after.events.map { $0.notes.map { after.notes[$0].absolute } }
        let original = tree.events.map { $0.notes.map { tree.notes[$0].absolute } }
        XCTAssertEqual(pitches, [original[0], original[1], original[2], original[1], original[2], original[3], original[4]])
        XCTAssertEqual(after.events.map(\.effectiveDuration), [0, 1, 2, 1, 2, 3, 4].map { tree.events[$0].effectiveDuration })
        XCTAssertEqual(edit.selectionAnchors, [after.events[3].range.lowerBound, after.events[4].range.lowerBound])
        XCTAssertEqual(edit.edits.inverse(original: tree.bytes).apply(to: text), source)
    }
}

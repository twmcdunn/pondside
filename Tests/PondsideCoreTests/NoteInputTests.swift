import XCTest
@testable import PondsideCore

final class NoteInputTests: XCTestCase {
    func ch(_ c: Character) -> KeyInput { KeyInput(.character(c)) }

    func testSystemAndPageBreakKeys() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0), [.toggleSystemBreak])
        XCTAssertEqual(input.handle(KeyInput(.enter, shift: true), now: 1), [.togglePageBreak])
    }

    func testDurationsAsInLilyPond() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(ch("8"), now: 0), [.setDuration(DurationValue(log: 3)), .buffer("")])
        // "1" applies a whole note, then "6" within the window refines to 16.
        XCTAssertEqual(input.handle(ch("1"), now: 1), [.setDuration(DurationValue(log: 0)), .buffer("1")])
        XCTAssertEqual(input.handle(ch("6"), now: 1.2), [.setDuration(DurationValue(log: 4)), .buffer("")])
        // "3" alone is not a duration: wait for "2".
        XCTAssertEqual(input.handle(ch("3"), now: 5), [.buffer("3")])
        XCTAssertEqual(input.handle(ch("2"), now: 5.1), [.setDuration(DurationValue(log: 5)), .buffer("")])
        // After the window, "1" then "6" are separate keys: 6 alone is a prefix of 64.
        _ = input.handle(ch("1"), now: 10)
        XCTAssertEqual(input.handle(ch("6"), now: 20), [.buffer("6")])
        XCTAssertEqual(input.armedDuration, DurationValue(log: 0))
    }

    func testPitchesRestsAndMoves() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(ch("g"), now: 0), [.insertNote(step: 4)])
        XCTAssertEqual(input.handle(ch("r"), now: 0), [.insertRest])
        XCTAssertEqual(input.handle(ch("i"), now: 0), [.invert])
        XCTAssertEqual(input.handle(KeyInput(.up), now: 0), [.move(.step(1))])
        XCTAssertEqual(input.handle(KeyInput(.down, shift: true), now: 0), [.move(.octave(-1))])
        XCTAssertEqual(input.handle(KeyInput(.up, option: true), now: 0), [.move(.chromatic(1))])
        XCTAssertEqual(input.handle(KeyInput(.right, shift: true), now: 0), [.select(step: 1, extend: true)])
        XCTAssertEqual(input.handle(KeyInput(.character("z"), command: true), now: 0), [], "⌘ keys belong to menus")
    }

    func testLilyPondSyntaxAsAccelerator() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(ch("("), now: 0), [.togglePostEvent("(")])
        XCTAssertEqual(input.handle(ch("^"), now: 0), [.buffer("^")])
        XCTAssertEqual(input.handle(ch("."), now: 0), [.togglePostEvent("^."), .buffer("")])
        XCTAssertEqual(input.handle(ch("^"), now: 0), [.buffer("^")])
        XCTAssertEqual(input.handle(ch("3"), now: 0), [.togglePostEvent("^3"), .buffer("")])
        for c in "\\tri" { _ = input.handle(ch(c), now: 0) }
        XCTAssertEqual(input.bufferText, "\\tri")
        _ = input.handle(ch("l"), now: 0)
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0), [.togglePostEvent("\\tril"), .buffer("")])
        _ = input.handle(ch("\\"), now: 0)
        XCTAssertEqual(input.handle(KeyInput(.escape), now: 0), [.buffer("")])
        XCTAssertFalse(input.isBuffering)
        // A direction followed by a non-articulation key falls through.
        _ = input.handle(ch("_"), now: 0)
        XCTAssertEqual(input.handle(ch("c"), now: 0), [.insertNote(step: 0)])
    }
    func testDirectSlurShortcutAndCancellation() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(ch("s"), now: 0), [.toggleSlur])
        _ = input.handle(ch("8"), now: 1)
        _ = input.handle(ch("="), now: 2)
        _ = input.handle(ch("\\"), now: 3)
        _ = input.handle(ch("t"), now: 4)
        XCTAssertTrue(input.isBuffering)
        input.cancelPendingInput()
        XCTAssertFalse(input.isBuffering)
        XCTAssertEqual(input.armedDuration, DurationValue(log: 3))
        XCTAssertEqual(input.armedAccidental, 2)
        XCTAssertEqual(input.handle(ch("s"), now: 5), [.toggleSlur])
    }
}

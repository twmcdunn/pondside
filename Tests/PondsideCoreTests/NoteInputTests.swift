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
        for c in "ll" { _ = input.handle(ch(c), now: 0) }
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0), [.togglePostEvent("\\trill"), .buffer("")])
        _ = input.handle(ch("\\"), now: 0)
        XCTAssertEqual(input.handle(KeyInput(.escape), now: 0), [.buffer("")])
        XCTAssertFalse(input.isBuffering)
        // ⎋ places an expression as ⏎ does; so does a click away.
        for c in "\\mf" { _ = input.handle(ch(c), now: 0) }
        XCTAssertEqual(input.handle(KeyInput(.escape), now: 0), [.addExpression("\\mf", each: false), .buffer("")])
        for c in "\\p" { _ = input.handle(ch(c), now: 0) }
        XCTAssertEqual(input.commitExpression(), [.addExpression("\\p", each: false), .buffer("")])
        XCTAssertEqual(input.commitExpression(), [])
        // A direction followed by a non-articulation key falls through.
        _ = input.handle(ch("_"), now: 0)
        XCTAssertEqual(input.handle(ch("c"), now: 0), [.insertNote(step: 0)])
    }
    func testHairpinKeys() {
        var input = NoteInput()
        XCTAssertEqual(input.handle(ch("<"), now: 0), [.hairpin(crescendo: true)])
        XCTAssertEqual(input.handle(ch(">"), now: 0), [.hairpin(crescendo: false)])
        // ^> is still an accent above.
        _ = input.handle(ch("^"), now: 0)
        XCTAssertEqual(input.handle(ch(">"), now: 0), [.togglePostEvent("^>"), .buffer("")])
    }

    func testExpressionEntry() {
        func type(_ s: String, _ input: inout NoteInput) { for c in s { _ = input.handle(c == "\t" ? KeyInput(.tab) : ch(c), now: 0) } }
        var input = NoteInput()
        type("\\mf  dol", &input)
        XCTAssertEqual(input.bufferText, "\\mf dol", "spaces collapse")
        XCTAssertEqual(input.completion, "ce")
        type("\t", &input)
        XCTAssertEqual(input.bufferText, "\\mf dolce")
        XCTAssertNil(input.completion)
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0),
                       [.addExpression("-#(make-dynamic-script (markup #:dynamic \"mf\" #:normal-text #:italic \"dolce\"))", each: false), .buffer("")])
        type("\\ff", &input)
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0), [.addExpression("\\ff", each: true), .buffer("")])
        type("_\\pppppp", &input)
        XCTAssertEqual(input.handle(KeyInput(.enter), now: 0), [.addExpression("_#(make-dynamic-script \"pppppp\")", each: true), .buffer("")])
        type("\\poco a p", &input)
        XCTAssertEqual(input.completion, "oco", "multi-word phrases complete")
        XCTAssertFalse(input.handle(ch(" "), now: 0).isEmpty, "space is part of the expression, not the leader")
    }

    func testExpressionParsing() {
        XCTAssertEqual(Expression.parse("poco f sub. p"), [.text("poco"), .dynamic("f"), .text("sub."), .dynamic("p")])
        XCTAssertEqual(Expression.parse("sul pont. mp"), [.text("sul pont."), .dynamic("mp")])
        XCTAssertEqual(Expression.postEvent("espressivo"), "-#(make-dynamic-script (markup #:normal-text #:italic \"espressivo\"))",
                       "espressivo is text, not the articulation")
        XCTAssertEqual(Expression.postEvent("fermata"), "\\fermata")
        XCTAssertEqual(Expression.postEvent("say \"hi\""), "-#(make-dynamic-script (markup #:normal-text #:italic \"say \\\"hi\\\"\"))")
        XCTAssertNil(Expression.completion(for: "p"), "a dynamic is complete")
        XCTAssertEqual(Expression.completion(for: "tri"), "ll")
        // What it writes parses as one post-event and is a dynamic mark.
        let text = "{ c'4-#(make-dynamic-script (markup #:dynamic \"mf\" #:normal-text #:italic \"dolce\")) d' }"
        let tree = SyntaxTree(text)
        XCTAssertEqual(tree.reconstructed, text)
        let e = tree.events[0]
        XCTAssertEqual(e.postEvents.count, 1)
        XCTAssertEqual(ScoreEditor(tree).mark(at: e.postEvents[0].lowerBound + 3)?.kind, .dynamic)
    }

    func testExpressionsReadBackAndReplace() {
        let mfDolce = Expression.postEvent("mf dolce")!
        XCTAssertEqual(Expression.elements(of: String(mfDolce.dropFirst())), [.dynamic("mf"), .text("dolce")])
        XCTAssertEqual(Expression.elements(of: "#(make-dynamic-script \"pppppp\")"), [.dynamic("pppppp")])
        XCTAssertEqual(Expression.elements(of: "\\mf"), [.dynamic("mf")])
        XCTAssertNil(Expression.elements(of: "\\trill"))
        // A new expression replaces the dynamic there; the same one again removes it.
        var text = "{ c'4\\p d'4 e' }"
        text = ScoreEditor(SyntaxTree(text)).setExpression(mfDolce, events: [0])!.edits.apply(to: text)
        XCTAssertEqual(text, "{ c'4\(mfDolce) d'4 e' }")
        text = ScoreEditor(SyntaxTree(text)).setExpression("\\f", events: [0])!.edits.apply(to: text)
        XCTAssertEqual(text, "{ c'4\\f d'4 e' }")
        text = ScoreEditor(SyntaxTree(text)).setExpression("\\f", events: [0])!.edits.apply(to: text)
        XCTAssertEqual(text, "{ c'4 d'4 e' }")
        // The lens shows it, and a hairpin ends there.
        let tree = SyntaxTree("{ c'4\\< d' e'4\(mfDolce) f' }")
        let lens = LensScoreBuilder.build(tree: tree, selection: tree.events[0].range, structure: nil)
        XCTAssertEqual(lens?.dynamics.map(\.text), ["mf dolce"])
        XCTAssertEqual(lens?.hairpins.count, 1)
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

import XCTest
@testable import PondsideCore

/// Electronics cues (`q`): placed at the selection's start on the score's cue
/// voice, selectable by their `\ecue`, deleted with their empty skip.
final class CueTests: XCTestCase {
    private func place(_ text: String, event: Int, file: StaticString = #filePath, line: UInt = #line) throws -> (String, CueStaves.Placement) {
        let tree = SyntaxTree(text)
        let target = try XCTUnwrap(CueStaves.cueVoice(trees: [tree]), file: file, line: line)
        let placed = try XCTUnwrap(CueStaves.insert(label: CueStaves.nextLabel(trees: [tree]), at: tree.events[event].range.lowerBound,
                                                    file: 0, into: target, trees: [tree], parse: { SyntaxTree($1) }),
                                   file: file, line: line)
        let result = (placed.edits[0] ?? []).apply(to: text)
        XCTAssertEqual(SyntaxTree(result).reconstructed, result, file: file, line: line)
        return (result, placed)
    }

    func testFindsCuesAndTheirLabels() {
        let tree = SyntaxTree("c = { s4*0\\ecue \"1\" \\edesc \"x\" s2 s4*0\\ecue \"2\" s2 }")
        XCTAssertEqual(tree.cues.map(\.label), ["1", "2"])
        XCTAssertEqual(tree.string(tree.cues[0].command), "\\ecue \"1\"")
        XCTAssertEqual(tree.cue(at: tree.cues[1].command.lowerBound + 2)?.label, "2")
    }

    /// The cue goes on the voice holding the cues, at the note's moment, splitting the skip.
    func testACueGoesOnTheCueVoiceAtTheSelectionsStart() throws {
        let text = "fl = { c'4 d' e' f' }\ncues = { s4*0\\ecue \"1\" s1 }\n\\score { << \\new Staff \\fl \\new Staff << \\cues >> >> }"
        let (result, placed) = try place(text, event: 2)
        XCTAssertEqual(result.split(separator: "\n")[1], "cues = { s4*0\\ecue \"1\" s2 s4*0\\ecue \"2\" s2 }")
        XCTAssertEqual(placed.label, "2")
        XCTAssertNil(placed.existing)
    }

    /// Before an event with no written duration, that event keeps its own.
    func testTheEventAfterTheCueKeepsItsDuration() throws {
        let text = "cues = { s4*0\\ecue \"1\" s4 s s s }\n\\score { \\new Staff \\cues }"
        let tree = SyntaxTree(text)
        let target = try XCTUnwrap(CueStaves.cueVoice(trees: [tree]))
        let s = tree.events.filter { $0.kind == .spacer }
        let placed = try XCTUnwrap(CueStaves.insert(label: "2", at: s[2].range.lowerBound, file: 0, into: target,
                                                    trees: [tree], parse: { SyntaxTree($1) }))
        XCTAssertEqual(placed.edits[0]?.apply(to: text).split(separator: "\n")[0],
                       "cues = { s4*0\\ecue \"1\" s4 s4*0\\ecue \"2\" s4 s s }")
    }

    /// With no cues yet, the electronics staff takes the first.
    func testTheFirstCueGoesOnTheElectronicsStaff() throws {
        let text = "fl = { c'4 d' e' f' }\nel = { s1 }\n\\score { << \\new Staff \\fl \\new Staff = \"elec\" \\el >> }"
        let (result, _) = try place(text, event: 3)
        XCTAssertEqual(result.split(separator: "\n")[1], "el = { s4*3 s4*0\\ecue \"1\" s4 }")
    }

    func testACueAlreadyAtTheMomentIsReturned() throws {
        let text = "fl = { c'4 d' }\ncues = { s4*0\\ecue \"1\" s2 }\n\\score { << \\new Staff \\fl \\new Staff \\cues >> }"
        let (result, placed) = try place(text, event: 0)
        XCTAssertEqual(result, text)
        XCTAssertEqual(placed.existing?.label, "1")
    }

    /// Deleting takes the empty skip too, but not one that carries more.
    func testDeletingACue() {
        let cases = [
            ("c = { s2 s4*0\\ecue \"3\" s2 }", "c = { s2 s2 }"),
            ("c = { s2 s4*0\\ecue \"3\" \\edesc \"swells\" s2 }", "c = { s2 s4*0 \\edesc \"swells\" s2 }"),
            ("c = { c'4\\ecue \"3\" d' }", "c = { c'4 d' }"),
        ]
        for (text, expected) in cases {
            let tree = SyntaxTree(text)
            let edit = ScoreEditor(tree).deleteCue(tree.cues[0])
            XCTAssertEqual(edit?.edits.apply(to: text), expected, text)
        }
    }

    func testNextLabelFollowsTheHighestNumber() {
        XCTAssertEqual(CueStaves.nextLabel(trees: [SyntaxTree("c = { s4*0\\ecue \"7\" s4*0\\ecue \"FxSwell\" s4*0\\ecue \"3\" }")]), "8")
        XCTAssertEqual(CueStaves.nextLabel(trees: [SyntaxTree("c = { s1 }")]), "1")
    }
}

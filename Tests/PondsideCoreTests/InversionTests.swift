import XCTest
@testable import PondsideCore

final class InversionTests: XCTestCase {
    private func inverted(_ source: String, _ events: [Int]) throws -> [String] {
        let tree = SyntaxTree(source)
        let edit = try XCTUnwrap(ScoreEditor(tree).invert(events: events))
        let text = edit.edits.apply(to: source)
        XCTAssertEqual(edit.edits.inverse(original: tree.bytes).apply(to: text), source)
        let after = SyntaxTree(text)
        return after.notes.filter { $0.role == .event }.map(\.absolute.description)
    }

    func testMirrorsAboutTheCentreOfTheRange() throws {
        XCTAssertEqual(try inverted("{ c'4 g' e' }", [0, 1, 2]), ["g'", "c'", "es'"])
        XCTAssertEqual(try inverted("{ <c' e' g'>2 }", [0]).sorted(), ["c'", "es'", "g'"])
        XCTAssertEqual(try inverted("{ d'4 fis' a' c'' }", [0, 1, 2, 3]), ["c''", "as'", "f'", "d'"])
    }

    func testKeepsRelativeMusicAroundTheSelection() throws {
        XCTAssertEqual(try inverted("\\relative c' { c4 g' e d }", [0, 1, 2]), ["g'", "c'", "es'", "d'"])
    }

    func testNeedsTwoNotes() {
        XCTAssertNil(ScoreEditor(SyntaxTree("{ c'4 d' }")).invert(events: [0]))
    }
}

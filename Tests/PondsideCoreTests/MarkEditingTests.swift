import XCTest
@testable import PondsideCore

/// Selecting an articulation, dynamic, hairpin or time signature (by the
/// source LilyPond links its grob to) and deleting it removes just that,
/// plus whatever would otherwise be left dangling.
final class MarkEditingTests: XCTestCase {
    private func offset(_ src: String, _ mark: String, nth: Int = 0) -> Int? {
        let hits = src.utf8.ranges(of: Array(mark.utf8))
        guard hits.indices.contains(nth) else { return nil }
        return src.utf8.distance(from: src.utf8.startIndex, to: hits[nth].lowerBound)
    }

    private func removing(_ src: String, _ mark: String, nth: Int = 0) -> String? {
        guard let at = offset(src, mark, nth: nth) else { return nil }
        let tree = SyntaxTree(src)
        guard let edit = ScoreEditor(tree).removeMark(at: at) else { return nil }
        let out = edit.edits.apply(to: src)
        XCTAssertEqual(edit.edits.inverse(original: tree.bytes).apply(to: out), src)
        XCTAssertEqual(SyntaxTree(out).reconstructed, out)
        return out
    }

    func testArticulationsAndDynamics() {
        XCTAssertEqual(removing("{ c'4-. d' }", "-."), "{ c'4 d' }")
        XCTAssertEqual(removing("{ c'4->\\f d' }", "->"), "{ c'4\\f d' }")
        XCTAssertEqual(removing("{ c'4->\\f d' }", "\\f"), "{ c'4-> d' }")
        XCTAssertEqual(removing("{ c'4 \\fermata d' }", "\\fermata"), "{ c'4 d' }")
        XCTAssertEqual(removing("{ c'4^\\markup { dolce } d' }", "^\\markup"), "{ c'4 d' }")
        XCTAssertEqual(removing("{ c'4~ c'8 }", "~"), "{ c'4 c'8 }")
    }

    func testNames() {
        let src = "{ c'4-. d'->\\mf e'\\< f'\\! }"
        let tree = SyntaxTree(src)
        func name(_ m: String) -> String? { offset(src, m).flatMap { ScoreEditor(tree).mark(at: $0)?.name } }
        XCTAssertEqual(name("-."), "Staccato")
        XCTAssertEqual(name("->"), "Accent")
        XCTAssertEqual(name("\\mf"), "Dynamic mf")
        XCTAssertEqual(name("\\<"), "Crescendo")
        XCTAssertNil(ScoreEditor(tree).mark(at: 2))   // the note itself
    }

    func testHairpinTakesItsTerminatorButNotADynamic() {
        XCTAssertEqual(removing("{ c'4\\< d' e'\\! f' }", "\\<"), "{ c'4 d' e' f' }")
        XCTAssertEqual(removing("{ c'4\\> d' e'\\p f' }", "\\>"), "{ c'4 d' e'\\p f' }")
        // A second hairpin's `\!` is not this one's.
        XCTAssertEqual(removing("{ c'4\\< d'\\> e'\\! }", "\\<"), "{ c'4 d'\\> e'\\! }")
    }

    func testBeamTakesItsEnd() {
        XCTAssertEqual(removing("{ c'8[ d' e' f'] g'2 }", "["), "{ c'8 d' e' f' g'2 }")
    }

    func testTweakGoesWithItsMark() {
        XCTAssertEqual(removing("{ c'4-\\tweak color #red ->  d' }", "->"), "{ c'4  d' }")
    }

    func testSlurStillRemovesBothEnds() {
        XCTAssertEqual(removing("{ c'4( d' e') f' }", "("), "{ c'4 d' e' f' }")
    }

    func testTimeSignature() throws {
        let src = "{ \\time 3/4 c'2. \\time 4/4 c'1 }"
        let tree = SyntaxTree(src)
        let at = try XCTUnwrap(offset(src, "\\time", nth: 1))
        let range = try XCTUnwrap(ScoreEditor(tree).timeSignature(at: at + 2))
        XCTAssertEqual(tree.string(range), "\\time 4/4")
        let edit = try XCTUnwrap(ScoreEditor(tree).removeTimeSignature(at: at))
        XCTAssertEqual(edit.edits.apply(to: src), "{ \\time 3/4 c'2. c'1 }")
        XCTAssertNil(ScoreEditor(tree).timeSignature(at: try XCTUnwrap(offset(src, "c'2."))))
    }
}

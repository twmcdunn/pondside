import XCTest
@testable import PondsideCore

/// Selecting a slur (by its `(`, where point-and-click links it) and
/// deleting it removes both of its ends, and only those.
final class SlurEditingTests: XCTestCase {
    /// Removes the slur whose mark is the `nth` occurrence of `mark`.
    private func removing(_ src: String, _ mark: String, nth: Int = 0) -> String? {
        let tree = SyntaxTree(src)
        let hits = src.utf8.ranges(of: Array(mark.utf8))
        guard hits.indices.contains(nth) else { return nil }
        let offset = src.utf8.distance(from: src.utf8.startIndex, to: hits[nth].lowerBound)
        return ScoreEditor(tree).removeSlur(at: offset)?.edits.apply(to: src)
    }

    func testRemovesBothEnds() {
        XCTAssertEqual(removing("{ c'4( d' e') f' }", "("), "{ c'4 d' e' f' }")
        XCTAssertEqual(removing("{ c'4^( d' e') f' }", "^("), "{ c'4 d' e' f' }")
    }

    func testFromTheClosingMark() {
        XCTAssertEqual(removing("{ c'4( d' e') f' }", ")"), "{ c'4 d' e' f' }")
    }

    func testPhrasingAndOrdinarySlursAreSeparate() {
        XCTAssertEqual(removing("{ c'4\\( d'( e') f'\\) }", "\\("), "{ c'4 d'( e') f' }")
        XCTAssertEqual(removing("{ c'4\\( d'( e') f'\\) }", "(", nth: 1), "{ c'4\\( d' e' f'\\) }")
    }

    func testAdjacentSlursOnOneNote() {
        let src = "{ a'4( b') ( c'' d'') }"
        XCTAssertEqual(removing(src, "(", nth: 1), "{ a'4( b') c'' d'' }")
        XCTAssertEqual(removing(src, "(", nth: 0), "{ a'4 b' ( c'' d'') }")
    }

    func testContinuesAcrossBraces() {
        XCTAssertEqual(removing("{ { c'4( d' } { e' f') } }", "("), "{ { c'4 d' } { e' f' } }")
    }

    func testSkipsOtherVoices() {
        let src = "{ c'4( << { d' e' } \\\\ { g( a) } >> f') }"
        XCTAssertEqual(removing(src, "(", nth: 0), "{ c'4 << { d' e' } \\\\ { g( a) } >> f' }")
        // A slur in a voice of its own ends inside it.
        XCTAssertEqual(removing(src, "(", nth: 1), "{ c'4( << { d' e' } \\\\ { g a } >> f') }")
    }

    func testDoesNotReachIntoTheNextVoice() {
        let src = "<< { c'4( d' } \\\\ { e' f') } >>"
        XCTAssertEqual(removing(src, "("), "<< { c'4 d' } \\\\ { e' f') } >>")
    }

    func testUnclosedSlurLosesItsOpening() {
        XCTAssertEqual(removing("{ c'4( d' }", "("), "{ c'4 d' }")
    }

    func testOnlySlurMarksCount() {
        let src = "{ c'4-. d' }"
        let offset = src.utf8.distance(from: src.utf8.startIndex, to: src.utf8.firstRange(of: Array("-.".utf8))!.lowerBound)
        XCTAssertNil(ScoreEditor(SyntaxTree(src)).slurMark(at: offset))
        XCTAssertNil(ScoreEditor(SyntaxTree(src)).removeSlur(at: offset))
    }

    func testDeletionSelectsTheOpeningNote() {
        let src = "{ b c'4( d') }"
        let tree = SyntaxTree(src)
        let offset = src.utf8.distance(from: src.utf8.startIndex, to: src.utf8.firstRange(of: Array("(".utf8))!.lowerBound)
        let edit = ScoreEditor(tree).removeSlur(at: offset)
        XCTAssertEqual(edit?.selectionAnchors, [4])
    }
}

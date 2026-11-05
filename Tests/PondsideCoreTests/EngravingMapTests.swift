import XCTest
@testable import PondsideCore

/// Edits made before the engraving lands are mapped span by span, so the
/// music between two edits keeps its exact place on the engraved page.
final class EngravingMapTests: XCTestCase {
    private func utf16(_ needle: String, in text: String, from: Int = 0) -> Int {
        let units = Array(text.utf16), n = Array(needle.utf16)
        for i in from...(units.count - n.count) where Array(units[i..<i + n.count]) == n { return i }
        return -1
    }

    /// Applying the hunks' new text in order gives the new text back.
    private func rebuild(_ old: String, _ new: String, _ hunks: [TextHunk]) -> String {
        let a = Array(old.utf16), b = Array(new.utf16)
        var out: [UInt16] = [], oldAt = 0, newAt = 0
        for h in hunks {
            out += a[oldAt..<h.oldLocation]
            newAt += h.oldLocation - oldAt
            out += b[newAt..<newAt + h.newLength]
            newAt += h.newLength
            oldAt = h.oldLocation + h.oldLength
        }
        out += a[oldAt...]
        return String(decoding: out, as: UTF16.self)
    }

    func testTwoEditsStayTwoHunks() {
        let old = "{ c'4 d' e' f' | g' a' b' c'' }"
        let new = "{ c'4( d' e') f' | g'( a' b') c'' }"
        let hunks = TextDiff.hunks(from: old, to: new)
        XCTAssertEqual(hunks.count, 4, "\(hunks)")
        XCTAssertEqual(rebuild(old, new, hunks), new)
    }

    func testRebuildsArbitraryEdits() {
        let cases = [("abcdef", "abXdeYf"), ("hello world", "help word!"), ("", "x"), ("x", ""), ("aaa", "aaaa"),
                     ("é𝄞c d", "é𝄞c( d)")]
        for (old, new) in cases {
            XCTAssertEqual(rebuild(old, new, TextDiff.hunks(from: old, to: new)), new, "\(old) → \(new)")
        }
        XCTAssertTrue(TextDiff.hunks(from: "same", to: "same").isEmpty)
    }

    func testTooManyEditsFallBackToOneSpan() {
        let old = String(repeating: "ab", count: 300), new = String(repeating: "cd", count: 300)
        let hunks = TextDiff.hunks(from: old, to: new, maxEdits: 16)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(rebuild(old, new, hunks), new)
    }

    /// A second slur added before the first one is engraved: the newly
    /// selected notes map to themselves in the engraved text, not back to
    /// the first slur.
    func testASecondEditMapsTheMusicBetweenExactly() {
        let engraved = "{ c'4 d' e' f' | g' a' b' c'' }"
        let current = "{ c'4( d' e') f' | g'( a' b') c'' }"
        let map = EngravingMap(engraved: engraved, current: current)
        let selection = utf16("g'(", in: current)
        XCTAssertEqual(map.engravedOffset(forCurrent: selection), utf16("g'", in: engraved))
        let end = utf16("b')", in: current) + 2
        XCTAssertEqual(map.engravedOffset(forCurrent: end), utf16("b'", in: engraved) + 2)
        // Text between the two edits maps both ways.
        let f = utf16("f'", in: current)
        XCTAssertEqual(map.engravedOffset(forCurrent: f), utf16("f'", in: engraved))
        XCTAssertEqual(map.currentOffset(forEngraved: utf16("f'", in: engraved)), f)
        // Inside inserted text collapses to where it was inserted.
        XCTAssertEqual(map.engravedOffset(forCurrent: utf16("(", in: current) + 1), utf16(" d'", in: engraved))
    }
}

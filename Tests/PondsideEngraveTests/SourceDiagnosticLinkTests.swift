import Foundation
import XCTest
import PondsideEngrave

final class SourceDiagnosticLinkTests: XCTestCase {
    func testMigrationSummaryAndCompilerLocations() throws {
        let message = """
        Could not prepare the score.

        /Users/me/My Score/electronics.ly:329: bar check failed at: 1/2
        flute.ily:12:9: warning: bar check failed
        patch/sound.scd:7: an error
        """
        let links = SourceDiagnosticLink.links(in: message)
        XCTAssertEqual(links.map(\.file), ["/Users/me/My Score/electronics.ly", "flute.ily", "patch/sound.scd"])
        XCTAssertEqual(links.map(\.line), [329, 12, 7])
        XCTAssertEqual(links.map(\.column), [nil, 9, nil])
        let first = try XCTUnwrap(links.first)
        XCTAssertEqual((message as NSString).substring(with: NSRange(location: first.range.lowerBound, length: first.range.count)), "/Users/me/My Score/electronics.ly:329")
    }

    func testUnicodeAndColonsPreserveLinkRanges() throws {
        let message = "𝄞 source error\n/Users/me/a:b/é score.ly:23:4: error: bad music"
        let link = try XCTUnwrap(SourceDiagnosticLink.links(in: message).first)
        XCTAssertEqual(link.file, "/Users/me/a:b/é score.ly")
        XCTAssertEqual(link.line, 23)
        XCTAssertEqual(link.column, 4)
        XCTAssertEqual((message as NSString).substring(with: NSRange(location: link.range.lowerBound, length: link.range.count)), "/Users/me/a:b/é score.ly:23:4")
    }

    func testUnlocatedMessagesAndWebAddressesAreNotSourceLinks() {
        let message = "warning: cannot prepare score\nhttps://example.com/score.ly:12: error\nscore.ly:0: error\nscore.ly:abc: error"
        XCTAssertTrue(SourceDiagnosticLink.links(in: message).isEmpty)
    }
}

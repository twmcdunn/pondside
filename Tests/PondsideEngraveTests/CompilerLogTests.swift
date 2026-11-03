import XCTest
@testable import PondsideEngrave

final class CompilerLogTests: XCTestCase {
    func testTheTailKeepsTheUsefulLines() {
        let log = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let tail = CompilerLog.tail(log, lines: 3)
        XCTAssertTrue(tail.contains("line 198"))
        XCTAssertTrue(tail.contains("line 200"))
        XCTAssertFalse(tail.contains("line 197"))
    }

    func testTheTailIsBoundedByCharacters() {
        let log = String(repeating: "x", count: 20_000)
        XCTAssertEqual(CompilerLog.tail(log, lines: 10, characters: 50).count, 50)
    }
}

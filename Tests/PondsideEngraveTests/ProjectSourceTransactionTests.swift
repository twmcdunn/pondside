import Foundation
import XCTest
import PondsideCore
import PondsideEngrave

final class ProjectSourceTransactionTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-transaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.ly"), b = dir.appendingPathComponent("b.ly")
        try Data("a before".utf8).write(to: a)
        try Data("b before".utf8).write(to: b)
        return (dir, a, b)
    }

    func testDiskConflictRejectsEntireProjectBeforeAnyWrite() throws {
        let (dir, a, b) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = [a: ContentHash("a before"), b: ContentHash("b before")]
        try Data("external".utf8).write(to: b)
        XCTAssertThrowsError(try ProjectSourceTransaction.replace(expected: expected, replacements: [a: "a after", b: "b after"]))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a before")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "external")
    }

    func testSecondWriteFailureRollsBackFirstFile() throws {
        let (dir, a, b) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = [a: ContentHash("a before"), b: ContentHash("b before")]
        XCTAssertThrowsError(try ProjectSourceTransaction.replace(expected: expected, replacements: [a: "a after", b: "b after"], write: { data, url in
            if url == b { throw ProjectSourceTransaction.Failure("disk full") }
            try data.write(to: url, options: .atomic)
        }))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a before")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b before")
    }

    func testRollbackNeverOverwritesAnExternalEdit() throws {
        let (dir, a, b) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = [a: ContentHash("a before"), b: ContentHash("b before")]
        XCTAssertThrowsError(try ProjectSourceTransaction.replace(expected: expected, replacements: [a: "a after", b: "b after"], write: { data, url in
            if url == b {
                try Data("external".utf8).write(to: a)
                throw ProjectSourceTransaction.Failure("disk full")
            }
            try data.write(to: url, options: .atomic)
        }))
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "external")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b before")
    }

    func testSuccessfulProjectWriteAndInverseRestoreExactBytes() throws {
        let (dir, a, b) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectSourceTransaction.replace(expected: [a: ContentHash("a before"), b: ContentHash("b before")], replacements: [a: "♭ after", b: "b after\n"])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "♭ after")
        try ProjectSourceTransaction.replace(expected: [a: ContentHash("♭ after"), b: ContentHash("b after\n")], replacements: [a: "a before", b: "b before"])
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a before")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b before")
    }
}

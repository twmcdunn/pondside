import XCTest
import Foundation
import PondsideCore
@testable import PondsideEngrave

final class UnmeteredInputTransactionTests: XCTestCase {
    func testEachProposedKeystrokeBuildsLensWithoutWritingSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("score.ly")
        let source = "\\score { \\new Staff { \\time 4/4 c'1 | d'1 } }"
        var files = [StructuralEditing.File(id: url.path, tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: url.path, sharedBreaks: true)
        let original = migration.flatMap(\.edits).apply(to: source)
        files[0].tree = SyntaxTree(original)
        try original.write(to: url, atomically: true, encoding: .utf8)
        let snapshot = UnmeteredInputTransaction.Snapshot(files: files, revisions: [url: ContentHash(original)], dirty: [])
        var anchor = files[0].tree.events.firstIndex { !$0.notes.isEmpty }!
        for (count, step) in [0, 1, 2, 3].enumerated() {
            let proposal = try UnmeteredInputTransaction.propose(.insert(step: step, duration: .quarter, octave: nil, accidental: nil),
                files: files, root: url.path, active: url.path, anchor: anchor)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
            XCTAssertEqual(proposal.tree.notes.filter { $0.role == .event }.count, count + 3)
            XCTAssertTrue(proposal.lens.events.contains { $0.isTarget && !$0.notes.isEmpty })
            XCTAssertFalse(proposal.lens.xml.isEmpty)
            try StructuralEditing.verifyLengths(proposal.plan.files, root: url.path)
            let prepared = UnmeteredInputTransaction.preparingCommit(proposal.plan, snapshot: snapshot)
            XCTAssertEqual(prepared.replacements[url], proposal.tree.text)
            XCTAssertEqual(UnmeteredInputTransaction.committedSnapshot(prepared).revisions[url], ContentHash(proposal.tree.text))
            files = proposal.plan.files
            anchor = try XCTUnwrap(proposal.tree.eventIndex(at: proposal.plan.selection))
        }
    }
}

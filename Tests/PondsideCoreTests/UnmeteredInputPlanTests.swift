import XCTest
@testable import PondsideCore

final class UnmeteredInputPlanTests: XCTestCase {
    func testBurstResizesContractAndKeepsInputOrder() throws {
        let source = "\\score { \\new Staff { \\time 4/4 c'1 | d'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: source))
        let anchor = files[0].tree.events.firstIndex { !$0.notes.isEmpty }!
        let requests = [0, 1, 2, 3, 4, 5, 6].map { UnmeteredInputPlan.Request.insert(step: $0, duration: .quarter, octave: nil, accidental: nil) }
        let result = try UnmeteredInputPlan.prepare(requests, files: files, root: "score.ly", active: "score.ly", anchor: anchor)
        try StructuralEditing.verifyLengths(result.files, root: "score.ly")
        XCTAssertEqual(result.files[0].tree.notes.filter { $0.role == .event }.count, 9)
        XCTAssertNotNil(result.files[0].tree.eventIndex(at: result.selection))
        XCTAssertEqual(result.files[0].tree.reconstructed, result.files[0].tree.text)
    }
    func testDraftChangesMapExistingNotesExactly() throws {
        let source = "\\score { \\new Staff { \\time 4/4 c'1 | d'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: source))
        let original = files[0].tree
        let notes = original.events.indices.filter { !original.events[$0].notes.isEmpty }
        var offset = original.events[notes[1]].range.lowerBound
        let requests = [0, 1, 2].map { UnmeteredInputPlan.Request.insert(step: $0, duration: .quarter, octave: nil, accidental: nil) }
        let result = try UnmeteredInputPlan.prepare(requests, files: files, root: "score.ly", active: "score.ly", anchor: notes[0])
        var replay = original.text
        for change in result.changes {
            XCTAssertEqual(change.file, "score.ly")
            offset = change.edits.mapOffset(offset)
            replay = change.edits.apply(to: replay)
        }
        XCTAssertEqual(replay, result.files[0].tree.text)
        let mapped = try XCTUnwrap(result.files[0].tree.eventIndex(at: offset))
        XCTAssertEqual(result.files[0].tree.string(result.files[0].tree.events[mapped].range), "d'1")
    }
    func testConstrainedEntryDoesNotReauditUnrelatedMeasures() throws {
        let source = "\\score { \\new Staff { c'1 | d'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        let managed = migration.flatMap(\.edits).apply(to: source)
        // A separate Source edit is unrelated to this note-entry command.
        files[0].tree = SyntaxTree(managed.replacingOccurrences(of: "d'1", with: "d'1 e'1"))
        let before = files[0].tree
        let anchor = before.events.firstIndex { !$0.notes.isEmpty }!
        let result = try UnmeteredInputPlan.prepare([.insert(step: 0, duration: .quarter, octave: nil, accidental: nil)],
            files: files, root: "score.ly", active: "score.ly", anchor: anchor)
        XCTAssertTrue(result.files[0].tree.text.contains("d'1 e'1"))
        XCTAssertEqual(StructuralEditing.measures(in: result.files[0].tree).map(\.name), StructuralEditing.measures(in: before).map(\.name))
        XCTAssertEqual(result.files[0].tree.notes.filter { $0.role == .event }.count, 4)
    }
    func testProposedContentEditsPreserveContractAndUndoName() throws {
        let source = "\\score { \\new Staff { c'4 d'4 e'2 | f'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: source))
        var anchor = files[0].tree.events.firstIndex { !$0.notes.isEmpty }!
        for kind in 0..<3 {
            let tree = files[0].tree
            let editor = ScoreEditor(tree)
            let edit: ScoreEdit?
            switch kind {
            case 0: edit = editor.move(events: [anchor], by: .step(1))
            case 1: edit = editor.setDuration(events: [anchor], to: DurationValue(text: "2")!)
            default: edit = editor.delete(events: [anchor])
            }
            let command = try XCTUnwrap(edit)
            let result = try UnmeteredInputPlan.prepare([.content(command)], files: files, root: "score.ly", active: "score.ly", anchor: anchor)
            XCTAssertEqual(result.name, command.name)
            try StructuralEditing.verifyLengths(result.files, root: "score.ly")
            XCTAssertEqual(StructuralEditing.measures(in: result.files[0].tree).map(\.name), StructuralEditing.measures(in: tree).map(\.name))
            files = result.files
            anchor = try XCTUnwrap(files[0].tree.eventIndex(at: result.selection))
        }
    }
    func testRapidActionsUseNewestDraftAndPreserveRangeSelection() throws {
        let source = "\\score { \\new Staff { c'4 d'4 e'4 f'4 | g'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: source))
        let tree = files[0].tree
        let notes = tree.events.indices.filter { !tree.events[$0].notes.isEmpty }
        let rangeEdit = try XCTUnwrap(ScoreEditor(tree).move(events: Array(notes.prefix(3)), by: .step(1)))
        let ranged = try UnmeteredInputPlan.prepare([.content(rangeEdit)], files: files, root: "score.ly", active: "score.ly", anchor: notes[0])
        XCTAssertEqual(ranged.files[0].tree.eventIndices(overlapping: ranged.selectionRange).count, 3)
        let rapid = try UnmeteredInputPlan.prepare([.action(.move(.step(1))), .action(.setDuration(DurationValue(text: "8")!)), .action(.move(.step(1)))],
            files: files, root: "score.ly", active: "score.ly", anchor: notes[0])
        let result = rapid.files[0].tree
        let selected = try XCTUnwrap(result.eventIndex(at: rapid.selection))
        XCTAssertEqual(result.notes[result.events[selected].notes[0]].absolute.step, 2)
        XCTAssertEqual(result.events[selected].effectiveDuration.text, "8")
        try StructuralEditing.verifyLengths(rapid.files, root: "score.ly")
    }
    func testHistoryRestoresExactSourceAndSelectionAcrossSharedMeterChanges() throws {
        let source = "\\score { \\new Staff { c'1 | d'1 | e'1 } }"
        var files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(source))]
        let migration = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        files[0].tree = SyntaxTree(migration.flatMap(\.edits).apply(to: source))
        let original = files[0].tree
        let target = original.events.indices.first { original.string(original.events[$0].range) == "d'1" }!
        let selection = original.events[target].range
        let deletion = try XCTUnwrap(ScoreEditor(original).delete(events: [target]))
        let deleted = try UnmeteredInputPlan.prepare([.content(deletion)], files: files, root: "score.ly", active: "score.ly", anchor: target)
        let undone = try UnmeteredInputPlan.prepare([.restore(texts: ["score.ly": original.text], selection: selection, name: deletion.name)],
            files: deleted.files, root: "score.ly", active: "score.ly", anchor: 0)
        XCTAssertEqual(undone.files[0].tree.text, original.text)
        XCTAssertEqual(undone.selectionRange, selection)
        XCTAssertEqual(undone.selection, selection.lowerBound)
        XCTAssertEqual(undone.name, deletion.name)
        let redone = try UnmeteredInputPlan.prepare([.restore(texts: ["score.ly": deleted.files[0].tree.text], selection: deleted.selectionRange, name: deletion.name)],
            files: undone.files, root: "score.ly", active: "score.ly", anchor: 0)
        XCTAssertEqual(redone.files[0].tree.text, deleted.files[0].tree.text)
        XCTAssertEqual(redone.selectionRange, deleted.selectionRange)
        try StructuralEditing.verifyLengths(redone.files, root: "score.ly")
    }
}

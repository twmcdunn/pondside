import XCTest
@testable import PondsideCore

final class StructuralEditingTests: XCTestCase {
    func testMigrationCommandIsReachableWithoutKeyboardConflicts() {
        XCTAssertTrue(CommandCatalog.standard.contains { $0.id == "file.migrateScore" && !$0.chords.isEmpty })
        XCTAssertTrue(Keymap().problems().isEmpty)
    }

    private func file(_ id: String, _ text: String) -> StructuralEditing.File {
        .init(id: id, tree: SyntaxTree(text))
    }

    private func apply(_ changes: [StructuralEditing.Change], to files: [StructuralEditing.File]) -> [StructuralEditing.File] {
        files.map { source in
            let edits = changes.filter { $0.file == source.id }.flatMap(\.edits)
            XCTAssertTrue(edits.isNonOverlapping)
            let text = edits.apply(to: source.tree.text)
            XCTAssertEqual(edits.inverse(original: source.tree.bytes).apply(to: text), source.tree.text)
            return file(source.id, text)
        }
    }

    private func managed(_ part: String = "flute = \\relative c' { \\time 4/4 c4 d e f | g1 \\break | a1 }\nelectronics = { s1 | s1 | s1 }") throws -> [StructuralEditing.File] {
        let files = [file("score.ly", "\\version \"2.24.3\"\n\\include \"part.ily\"\n\\score { << \\new Staff \\flute \\new Staff \\electronics >> }"), file("part.ily", part)]
        return apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
    }

    func testMigrationCentralizesMetersAndBreaksBeforeIncludes() throws {
        let files = try managed()
        XCTAssertTrue(StructuralEditing.isManaged(files[0].tree))
        XCTAssertTrue(StructuralEditing.managesBreaks(files[0].tree))
        XCTAssertTrue(files[0].tree.text.contains("pondsideBarB = { \\time 4/4 s1*4/4 \\break }"))
        XCTAssertFalse(files[1].tree.text.contains("\\time"))
        XCTAssertFalse(files[1].tree.text.contains("\\break"))
        XCTAssertEqual(StructuralEditing.measures(in: files[1].tree).count, 6)
        XCTAssertEqual(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true).count, 0)
    }

    func testMeterEditChangesOnlyTheSharedDefinition() throws {
        let files = try managed()
        let changes = try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly")
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].file, "score.ly")
        let after = apply(changes, to: files)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: "pondsideBarA"), .init(beats: 5, beatType: 4))
        XCTAssertEqual(after[1].tree.text, files[1].tree.text)
    }

    func testNoteEntryContinuesIntoNextMeasureAndChecksThatMeasure() throws {
        for nextMusic in ["s1", "d'1"] {
            let files = try managed("flute = { c'1 | \(nextMusic) }\nelectronics = { s1 | s1 }")
            let before = files[1].tree
            let anchor = try XCTUnwrap(before.events.indices.first { before.events[$0].kind == .note })
            let next = try XCTUnwrap(StructuralEditing.nextMeasureForEntry(after: anchor, in: before, root: files[0].tree))
            XCTAssertEqual(next.name, "pondsideBarB")
            let edit = try XCTUnwrap(ScoreEditor(before).insert(step: 2, after: anchor, duration: .quarter, insertionAt: next.body.lowerBound))
            let proposed = SyntaxTree(edit.edits.apply(to: before.text))
            let originalNotes = before.notes.filter { $0.role == .event }.map(\.absolute)
            XCTAssertEqual(proposed.notes.filter { $0.role == .event && !edit.selectionAnchors.contains($0.name.lowerBound) }.map(\.absolute), originalNotes)
            if nextMusic == "s1" {
                try StructuralEditing.verifyContentEdit(in: "part.ily", before: before, proposed: proposed, root: files[0].tree)
            } else {
                XCTAssertThrowsError(try StructuralEditing.verifyContentEdit(in: "part.ily", before: before, proposed: proposed, root: files[0].tree))
            }
            XCTAssertEqual(before.string(StructuralEditing.measures(in: before)[0].body), proposed.string(StructuralEditing.measures(in: proposed)[0].body))
            XCTAssertEqual(edit.edits.inverse(original: before.bytes).apply(to: proposed.text), before.text)
        }
    }

    func testNoteEntryDoesNotSkipPartialBarsOrJumpToAnotherVoice() throws {
        let files = try managed("flute = { c'1 | d'1 }\nelectronics = { s1 | s1 }")
        let second = StructuralEditing.measures(in: files[1].tree)[1]
        for tree in [files[1].tree, SyntaxTree([TextEdit(second.body, "d'2")].apply(to: files[1].tree.text))] {
            let last = try XCTUnwrap(tree.events.indices.last { tree.events[$0].kind == .note })
            XCTAssertEqual(StructuralEditing.nextMeasureForEntry(after: last, in: tree, root: files[0].tree)?.name, nil)
        }
    }

    func testBoundaryEntryPreservesRelativePitchesAndInheritedDuration() throws {
        var files = try managed("flute = \\relative c'' { c1 | g1 }\nelectronics = { s1 | s1 }")
        let second = StructuralEditing.measures(in: files[1].tree)[1]
        files[1].tree = SyntaxTree([TextEdit(second.body, "g2")].apply(to: files[1].tree.text))
        let before = files[1].tree
        let oldPitches = before.notes.filter { $0.role == .event }.map(\.absolute)
        let anchor = try XCTUnwrap(before.events.indices.first { before.events[$0].kind == .note })
        let next = try XCTUnwrap(StructuralEditing.nextMeasureForEntry(after: anchor, in: before, root: files[0].tree))
        for duration in [DurationValue?.none, .some(.quarter)] {
            let edit = try XCTUnwrap(ScoreEditor(before).insert(step: 2, after: anchor, duration: duration, insertionAt: next.body.lowerBound))
            let after = SyntaxTree(edit.edits.apply(to: before.text))
            let pitches = after.notes.filter { $0.role == .event && !edit.selectionAnchors.contains($0.name.lowerBound) }.map(\.absolute)
            XCTAssertEqual(pitches, oldPitches)
            XCTAssertEqual(after.events.last(where: { $0.kind == .note })?.effectiveDuration, DurationValue(log: 1))
        }
        let rests = try managed("flute = { R1 | s1 }\nelectronics = { s1 | s1 }")
        let rest = try XCTUnwrap(rests[1].tree.events.indices.first { rests[1].tree.events[$0].kind == .multiMeasureRest })
        XCTAssertEqual(StructuralEditing.nextMeasureForEntry(after: rest, in: rests[1].tree, root: rests[0].tree)?.name, "pondsideBarB")
    }

    func testLocalNoteCheckIgnoresUneditedMeasuresAndBlocksOverflow() throws {
        let files = try managed()
        let original = files[1].tree
        let measure = StructuralEditing.measures(in: original)[0]
        let overflow = SyntaxTree([TextEdit(measure.body, "c'1 d'4")].apply(to: original.text))
        XCTAssertThrowsError(try StructuralEditing.verifyContentEdit(in: "part.ily", before: original, proposed: overflow, root: files[0].tree))
        let unrelated = StructuralEditing.measures(in: original)[1]
        let before = SyntaxTree([TextEdit(unrelated.body, "d'1 d'1")].apply(to: original.text))
        let first = StructuralEditing.measures(in: before)[0]
        let proposed = SyntaxTree([TextEdit(first.body, "c'2")].apply(to: before.text))
        try StructuralEditing.verifyContentEdit(in: "part.ily", before: before, proposed: proposed, root: files[0].tree)
    }

    func testUnmeteredShorteningPreservesRoomForOtherVoices() throws {
        var files = try managed("flute = { c'1 }\nelectronics = { d'1 }")
        let other = StructuralEditing.measures(in: files[1].tree)[1]
        files[1].tree = SyntaxTree([TextEdit(other.body, "d'2.")].apply(to: files[1].tree.text))
        let first = StructuralEditing.measures(in: files[1].tree)[0]
        let proposed = SyntaxTree([TextEdit(first.body, "c'4")].apply(to: files[1].tree.text))
        let changes = try StructuralEditing.resizingForContentChange(in: "part.ily", proposed: proposed, files: files, root: "score.ly")
        let after = apply(changes, to: files)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: "pondsideBarA"), .init(beats: 3, beatType: 4))
    }

    func testShorterMeterNeverCutsSoundingContent() throws {
        let files = try managed()
        XCTAssertThrowsError(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"))
    }

    func testSpacerMeasuresAreElasticButMusicalRestsArePreserved() throws {
        let files = try managed("flute = { c1 | c1 | c1 }\nelectronics = { s1 | r1 | R1 }")
        XCTAssertEqual(files[1].tree.events.filter { $0.kind == .spacer }.count, 1)
        XCTAssertTrue(files[1].tree.text.contains("s1*0"))
        XCTAssertTrue(files[1].tree.text.contains("r1"))
        XCTAssertTrue(files[1].tree.text.contains("R1"))
        XCTAssertThrowsError(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 4), measure: "pondsideBarB", files: files, root: "score.ly"))
    }

    func testBreakBeforeSelectionEditsPrecedingMeasureOnly() throws {
        let files = try managed()
        let after = apply(try StructuralEditing.toggleBreak(before: "pondsideBarC", files: files, root: "score.ly"), to: files)
        XCTAssertFalse(after[0].tree.text.contains("s1*4/4 \\break"))
        let again = apply(try StructuralEditing.toggleBreak(before: "pondsideBarC", files: after, root: "score.ly"), to: after)
        XCTAssertEqual(again[0].tree.text, files[0].tree.text)
        XCTAssertThrowsError(try StructuralEditing.toggleBreak(before: "pondsideBarA", files: files, root: "score.ly"))
    }

    func testNestedTremoloSelectionFindsEnclosingMeasure() throws {
        let files = try managed("flute = { \\time 5/4 e'2 \\repeat tremolo 8 { gis'32 e'32 } r4 | c'1 r4 }\nelectronics = { \\time 5/4 s1*5/4 | s1*5/4 }")
        let tree = files[1].tree
        let event = try XCTUnwrap(tree.events.first { $0.effectiveDuration.log == 5 })
        let measure = try XCTUnwrap(StructuralEditing.measure(in: tree, at: event.range.lowerBound))
        XCTAssertEqual(measure.name, "pondsideBarA")
        let changes = try StructuralEditing.changeMeter(.init(beats: 6, beatType: 4), measure: measure.name, files: files, root: "score.ly")
        XCTAssertEqual(changes[0].file, "score.ly")
        XCTAssertEqual(changes[0].edits.count, 1)
    }

    func testInheritedDurationsAreExplicitAtNewMeasureStarts() throws {
        let files = try managed("flute = { c4 d e f | g a b c }\nelectronics = { s1 | s1 }")
        XCTAssertTrue(files[1].tree.text.contains("{ g4 a b c"))
    }

    func testTupletContentLengthUsesAllNotesAndScaling() throws {
        let files = try managed("flute = { \\tuplet 3/2 { c'4 d' e' } f'2 }\nelectronics = { s1 }")
        let measure = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        XCTAssertEqual(StructuralEditing.contentMeter(in: files[1].tree, measure: measure), .init(beats: 1, beatType: 1))
    }

    func testSharedBreaksCanBeUncheckedAndReenabled() throws {
        let files = try managed()
        let local = apply(try StructuralEditing.settingBreaks(false, files: files, root: "score.ly"), to: files)
        XCTAssertFalse(StructuralEditing.managesBreaks(local[0].tree))
        XCTAssertTrue(local[1].tree.text.contains("\\break"))
        XCTAssertThrowsError(try StructuralEditing.toggleBreak(before: "pondsideBarC", files: local, root: "score.ly"))
        let shared = apply(try StructuralEditing.settingBreaks(true, files: local, root: "score.ly"), to: local)
        XCTAssertTrue(StructuralEditing.managesBreaks(shared[0].tree))
        XCTAssertFalse(shared[1].tree.text.contains("\\break"))
        XCTAssertEqual(StructuralEditing.time(in: shared[0].tree, name: "pondsideBarB"), .common)
    }

    func testRemovingContractPreservesMeterAndBreaksAsOrdinarySource() throws {
        let files = try managed()
        let after = apply(try StructuralEditing.removeContract(files, root: "score.ly"), to: files)
        XCTAssertFalse(StructuralEditing.isManaged(after[0].tree))
        XCTAssertFalse(after[0].tree.text.contains("pondsideMeasure"))
        XCTAssertFalse(after[1].tree.text.contains("pondsideMeasure"))
        XCTAssertTrue(after[1].tree.text.contains("\\time 4/4"))
        XCTAssertTrue(after[1].tree.text.contains("\\break"))
        XCTAssertTrue(after[1].tree.text.contains("s1*1/1"))
    }

    func testAppendMeasureAddsOneSharedDefinitionAndEveryVoice() throws {
        let files = try managed()
        let after = apply(try StructuralEditing.appendMeasure(after: "pondsideBarC", time: .init(beats: 3, beatType: 2), files: files, root: "score.ly"), to: files)
        XCTAssertEqual(StructuralEditing.measures(in: after[1].tree).filter { $0.name == "pondsideBarD" }.count, 2)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: "pondsideBarD"), .init(beats: 3, beatType: 2))
        XCTAssertThrowsError(try StructuralEditing.appendMeasure(after: "pondsideBarA", time: .common, files: files, root: "score.ly"))
    }

    func testAmbiguousOrInconsistentSourceIsRefused() {
        let cases = [
            "{ \\repeat volta 2 { c'1 } }",
            "{ \\partial 4 c'4 | d'1 }",
            "{ c'2 \\time 3/4 d'2 }",
            "{ c'1 d'1 }", // no editable boundary between these measures
            "{ \\unknownMusic c'1 }",
            "{ << { c'1 } \\\\ { e'1 } >> }",
            "{ c'2 \\break d'2 }",
            "global = { \\time 4/4 } a = { c'1 }",
        ]
        for text in cases {
            XCTAssertThrowsError(try StructuralEditing.migrate([file("score.ly", text)], root: "score.ly", sharedBreaks: true), text)
        }
    }

    func testUnmeteredNotesResizeTheWholeSharedMeasure() throws {
        var files = try managed("flute = { c'1 }\nelectronics = { s1 }")
        let body = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        files[1] = file("part.ily", [TextEdit(body.body, " e''16 fis'' gis'' b'' cis''' b'' gis'' fis'' e'' fis'' gis'' b'' d''' b'' gis'' fis'' e'' fis'' gis'' c''' d''' c''' gis'' fis'' ")].apply(to: files[1].tree.text))
        let updated = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        let time = try XCTUnwrap(StructuralEditing.contentMeter(in: files[1].tree, measure: updated))
        XCTAssertEqual(time, .init(beats: 3, beatType: 2))
        let after = apply(try StructuralEditing.changeMeter(time, measure: updated.name, files: files, root: "score.ly"), to: files)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: "pondsideBarA"), .init(beats: 3, beatType: 2))
    }
    func testMeterInOneDependencyAppliesToOtherVoices() throws {
        let files = try managed("flute = { \\time 5/4 c'1 r4 | \\time 3/2 c'1 r2 }\nelectronics = { s1*5/4 | s1*3/2 }")
        XCTAssertEqual(StructuralEditing.time(in: files[0].tree, name: "pondsideBarA"), .init(beats: 5, beatType: 4))
        XCTAssertEqual(StructuralEditing.time(in: files[0].tree, name: "pondsideBarB"), .init(beats: 3, beatType: 2))
    }

    func testEmptyMeasureAnchorHasNoDurationDuringUnmeteredEntry() throws {
        var files = try managed("flute = { s1 }\nelectronics = { s1 }")
        let first = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        files[1] = file("part.ily", [TextEdit(first.body, " s1*0 c'16 ")].apply(to: files[1].tree.text))
        let measure = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        XCTAssertEqual(StructuralEditing.contentMeter(in: files[1].tree, measure: measure), .init(beats: 1, beatType: 16))
        let after = apply(try StructuralEditing.changeMeter(.init(beats: 1, beatType: 16), measure: measure.name, files: files, root: "score.ly"), to: files)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: measure.name), .init(beats: 1, beatType: 16))
    }

    func testFullMeasureRestsFollowSharedLength() throws {
        let files = try managed("flute = { s1 }\nelectronics = { R1 }")
        let after = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 8), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        XCTAssertTrue(after[1].tree.text.contains("R1"))
        let ordinary = apply(try StructuralEditing.removeContract(after, root: "score.ly"), to: after)
        XCTAssertTrue(ordinary[1].tree.text.contains("R1*5/8"))
    }

    func testDamagedContractsCannotSilentlyReceiveLocalStructuralEdits() throws {
        let files = try managed()
        let corruptions = [
            files[1].tree.text.replacingOccurrences(of: "c4 d e f", with: "c4 \\time 3/4 d e f"),
            files[1].tree.text.replacingOccurrences(of: "c4 d e f", with: "c4 \\break d e f"),
            files[1].tree.text + "\nother = { c'1 }",
            files[1].tree.text.replacingOccurrences(of: "\\pondsideBarB", with: "\\pondsideBarA"),
        ]
        for text in corruptions {
            let changed = [files[0], file("part.ily", text)]
            XCTAssertThrowsError(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: changed, root: "score.ly"))
            XCTAssertThrowsError(try StructuralEditing.toggleBreak(before: "pondsideBarB", files: changed, root: "score.ly"))
        }
    }

    func testLensUsesSharedMetersAndPaddingAcrossDependencyFiles() throws {
        var files = try managed("flute = { c'1 | d'1 }\nelectronics = { s1 | s1 }")
        files = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        let target = try XCTUnwrap(files[1].tree.events.first { $0.kind == .note && files[1].tree.string($0.range).hasPrefix("d'") })
        let lens = try XCTUnwrap(LensScoreBuilder.build(tree: files[1].tree, selection: target.range, structure: files[0].tree))
        XCTAssertEqual(lens.target?.measureIndex, 1)
        XCTAssertTrue(lens.unsupported.isEmpty)
        XCTAssertTrue(lens.xml.contains("<beats>5</beats><beat-type>4</beat-type>"))
        XCTAssertTrue(lens.xml.contains("<beats>4</beats><beat-type>4</beat-type>"))
    }

    func testTimedCommandsPreventSpacerContentFromBeingCollapsed() throws {
        let files = try managed("flute = { c'1 }\nelectronics = { s2 \\tempo 4 = 60 s2 }")
        XCTAssertTrue(files[1].tree.text.contains("\\tempo 4 = 60"))
        XCTAssertEqual(StructuralEditing.spaces(in: files[1].tree, body: files[1].tree.root.range).map(\.fraction), [LensFraction(1, 2), LensFraction(1, 2)])
        XCTAssertThrowsError(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"))
    }

    func testOrdinaryTextDoesNotDisableStructuralEditing() throws {
        let files = try managed("flute = { c'1 ^\\markup \\italic \"dolce\" }\nelectronics = { s1 }")
        let after = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        try StructuralEditing.verifyLengths(after, root: "score.ly")
    }

    func testOrdinaryOverflowIsRefusedAndEmptyMeasuresRemainValid() throws {
        var files = try managed("flute = { c'1 }\nelectronics = { s1 }")
        let measure = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        let original = files[1].tree.text
        files[1] = file("part.ily", [TextEdit(measure.body, " c'1 d'1 ")].apply(to: original))
        XCTAssertThrowsError(try StructuralEditing.verifyLengths(files, root: "score.ly"))
        files[1] = file("part.ily", [TextEdit(measure.body, " ")].apply(to: original))
        try StructuralEditing.verifyLengths(files, root: "score.ly")
    }

    func testUnmeteredPlannerPairsOccurrencesInDifferentVoices() throws {
        var files = try managed("flute = { c'1 }\nelectronics = { d'1 }")
        let occurrences = StructuralEditing.measures(in: files[1].tree)
        files[1] = file("part.ily", [TextEdit(occurrences[1].body, " d'2 ")].apply(to: files[1].tree.text))
        let first = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        let proposed = SyntaxTree([TextEdit(first.body, " c'1 e'4 ")].apply(to: files[1].tree.text))
        let changes = try StructuralEditing.resizingForContentChange(in: "part.ily", proposed: proposed, files: files, root: "score.ly")
        files[1].tree = proposed
        let after = apply(changes, to: files)
        XCTAssertEqual(StructuralEditing.time(in: after[0].tree, name: "pondsideBarA"), .init(beats: 5, beatType: 4))
        XCTAssertTrue(after[1].tree.text.contains("d'2"))
    }

    func testUnmeteredPlannerHandlesDurationDotAndDeletion() throws {
        var files = try managed("flute = { c'1 }\nelectronics = { s1 }")
        for (music, expected) in [("c'2", LensTime(beats: 1, beatType: 2)), ("c'2.", LensTime(beats: 3, beatType: 4)), (" ", LensTime(beats: 3, beatType: 4))] {
            let measure = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
            let proposed = SyntaxTree([TextEdit(measure.body, music)].apply(to: files[1].tree.text))
            let changes = try StructuralEditing.resizingForContentChange(in: "part.ily", proposed: proposed, files: files, root: "score.ly")
            files[1].tree = proposed
            files = apply(changes, to: files)
            XCTAssertEqual(StructuralEditing.time(in: files[0].tree, name: "pondsideBarA"), expected)
        }
    }

    func testAmbiguousReuseIsRefusedButSeparatePrintAndMidiScoresAreAllowed() throws {
        var files = try managed()
        files[0] = file("score.ly", files[0].tree.text + "\n\\score { \\new Staff \\flute }")
        try StructuralEditing.validate(files, root: "score.ly")
        files[0] = file("score.ly", files[0].tree.text.replacingOccurrences(of: "\\new Staff \\flute", with: "\\new Staff { \\flute \\flute }"))
        XCTAssertThrowsError(try StructuralEditing.validate(files, root: "score.ly"))
    }

    func testAppendingMovesTheFinalBarlineToTheNewLastMeasure() throws {
        let files = try managed("flute = { c'1 \\bar \"|.\" }\nelectronics = { s1 }")
        let after = apply(try StructuralEditing.appendMeasure(after: "pondsideBarA", time: .common, files: files, root: "score.ly"), to: files)
        let measures = StructuralEditing.measures(in: after[1].tree)
        XCTAssertFalse(after[1].tree.string(measures[0].body).contains("\\bar"))
        XCTAssertTrue(after[1].tree.string(measures[1].body).contains("\\bar \"|.\""))
    }

    func testDefaultsOfferOnlyConverterRepairs() {
        let root = """
        % musicxml2ly
        \\paper {
          left-margin = 30\\mm
        }
        \\score {
          { c'1 }
          \\layout {
            \\context {
              \\Score
              autoBeaming = ##f
            }
            \\context {
              \\Staff
              printKeyCancellation = ##f
            }
          }
        }
        """
        let choices = ConvertedScoreCheck.restorationSettings(root: root)
        XCTAssertEqual(choices.map(\.id), ["score.autoBeaming", "staff.keyCancellation"])
        let doc = EngravingSettingsDocument(root: root)
        let result = doc.edits(for: choices.map { ($0, $0.defaultValue) }).apply(to: root)
        XCTAssertTrue(result.contains("left-margin = 30\\mm"))
        XCTAssertEqual(ConvertedScoreCheck.restorationSettings(root: "\\score { { c'1 } \\layout { \\context { \\Score autoBeaming = ##f } } }").count, 0)
    }

    func testGroupedLayoutRepeatsAndSpacingSectionsMigrate() throws {
        let files = try managed("flute = { c'1 | d'1 | e'1 | f'1 | g'1 | a'1 }\nelectronics = { \\autoLineBreaksOff \\autoPageBreaksOff \\newSpacingSection \\override Score.SpacingSpanner.spacing-increment = #0.75 s1 s1 \\break | s1*2 \\pageBreak | \\repeat unfold 2 { s1 | } }")
        XCTAssertTrue(files[0].tree.text.contains("pondsideBarB = { \\time 4/4 s1*4/4 \\break }"))
        XCTAssertTrue(files[0].tree.text.contains("pondsideBarD = { \\time 4/4 s1*4/4 \\pageBreak }"))
        XCTAssertTrue(files[1].tree.text.contains("\\autoLineBreaksOff \\autoPageBreaksOff"))
        XCTAssertTrue(files[1].tree.text.contains("\\newSpacingSection"))
        XCTAssertTrue(files[1].tree.text.contains("spacing-increment = #0.75"))
        XCTAssertFalse(files[1].tree.text.contains("\\repeat unfold"))
        XCTAssertFalse(files[1].tree.text.contains("\\break"))
        XCTAssertFalse(files[1].tree.text.contains("\\pageBreak"))
        try StructuralEditing.verifyLengths(files, root: "score.ly")
    }

    func testLongSkipsSplitAtMeasureBoundariesAndRetainInternalAnchors() throws {
        let files = try managed("flute = { c'1 | d'1 }\nelectronics = { s1*3/2 \\newSpacingSection s2 \\break }")
        XCTAssertTrue(files[1].tree.text.contains("\\pondsideSpace \\pondsideBarB #1 #2"))
        let after = apply(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 2), measure: "pondsideBarB", files: files, root: "score.ly"), to: files)
        let ordinary = apply(try StructuralEditing.removeContract(after, root: "score.ly"), to: after)
        XCTAssertFalse(ordinary[1].tree.text.contains("\\pondsideSpace"))
        XCTAssertTrue(ordinary[1].tree.text.contains("s1*3/4"))
        XCTAssertTrue(ordinary[1].tree.text.contains("\\newSpacingSection"))
    }

    func testShortLayoutTracksArePaddedAndMidMeasureBreaksAreExplained() throws {
        let files = try managed("flute = { c'1 | d'1 }\nelectronics = { s1 }")
        XCTAssertEqual(StructuralEditing.measures(in: files[1].tree).count, 4)
        XCTAssertThrowsError(try managed("flute = { c'1 | d'1 }\nelectronics = { s2 \\break s1*3/2 }"))
    }

    func testEmptyChordsDoNotAddDurationToLayoutTracks() throws {
        let files = try managed("flute = { c'1 | d'1 }\nelectronics = { <>\\p s2 <>\\f s1 \\newSpacingSection s2 }")
        try StructuralEditing.verifyLengths(files, root: "score.ly")
        XCTAssertTrue(files[1].tree.text.contains("<>\\p"))
        XCTAssertTrue(files[1].tree.text.contains("<>\\f"))
    }

    func testHelperTemplatesAndFrontMatterDoNotBecomeScoreVoices() throws {
        let source = "helper = #(define-music-function () () #{ c'4 #})\n\\markup \\score { { d'2 } \\layout {} }\nflute = { e'1 }\nelectronics = { s1 }"
        let files = try managed(source)
        XCTAssertTrue(files[1].tree.text.contains("helper = #(define-music-function () () #{ c'4 #})"))
        XCTAssertTrue(files[1].tree.text.contains("\\markup \\score { { d'2 } \\layout {} }"))
        XCTAssertEqual(StructuralEditing.measures(in: files[1].tree).count, 2)
    }

    func testGeneratedLegendBookpartIsNotAnInterpretedVoice() throws {
        let original = FrontMatter.template([.legend])
        let legend = FrontMatter(original).edits(adding: [.init(id: "example", title: "Example", text: "Legend excerpt",
            example: FrontMatter.example(music: "\\time 3/4 c'2."))]).apply(to: original)
        // The real score follows the generated bookpart in the same file:
        // excluding front matter must not exclude the remainder of that file.
        let root = legend + "\n\\score { << \\new Staff \\flute \\new Devnull \\structure >> }"
        let files = [file("score.ly", root), file("part.ily", "flute = { c'1 }\nstructure = { s1 }")]
        let prepared = try StructuralEditing.prepareForInterpretation(files)
        XCTAssertEqual(prepared[0].tree.text, root)
        let regions = try StructuralEditing.regionsForInterpretation(prepared)
        XCTAssertEqual(regions.count, 2)
        XCTAssertTrue(regions.allSatisfy { $0.file == "part.ily" })
    }

    func testRestoreUpdatesOnlyTheGeneratedHelperWhenReapplyingContract() throws {
        var files = try managed()
        let original = files[1].tree.text
        files[0] = file("score.ly", files[0].tree.text.replacingOccurrences(of: "(ly:moment-sub expected actual)", with: "(ly:moment-sub expected  actual)"))
        let changes = try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        let after = apply(changes, to: files)
        try StructuralEditing.validate(after, root: "score.ly")
        XCTAssertEqual(after[1].tree.text, original)
        XCTAssertEqual(try StructuralEditing.migrate(after, root: "score.ly", sharedBreaks: true).count, 0)
    }

}

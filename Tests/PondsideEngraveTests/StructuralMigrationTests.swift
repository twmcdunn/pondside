import Foundation
import XCTest
import PondsideCore
import PondsideEngrave

final class StructuralMigrationTests: XCTestCase {
    private func installation() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return lily
    }
    private func fixture(_ part: String, definitions: String = "", score: String = "\\score { << \\new Staff \\flute \\new Devnull \\structure >> }") throws -> (URL, [StructuralEditing.File]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-migration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = dir.appendingPathComponent("score.ly")
        try Data(("\\version \"2.24.3\"\n" + definitions + "\n\\include \"part.ily\"\n" + score).utf8).write(to: root)
        try Data(part.utf8).write(to: dir.appendingPathComponent("part.ily"))
        let graph = SourceGraph.load(root: root)
        let files = graph.files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree, entryLanguage: $0.entryLanguage) }
        return (graph.root.url, files)
    }
    private func apply(_ plan: StructuralMigration.Plan, to files: [StructuralEditing.File]) -> [StructuralEditing.File] {
        files.map { file in
            var result = file
            let edits = plan.changes.filter { $0.file == file.id }.flatMap(\.edits)
            XCTAssertTrue(edits.isNonOverlapping)
            result.tree = result.parse(edits.apply(to: file.tree.text))
            XCTAssertEqual(edits.inverse(original: file.tree.bytes).apply(to: result.tree.text), file.tree.text)
            return result
        }
    }
    private func unchanged(_ files: [StructuralEditing.File]) throws {
        for file in files { XCTAssertEqual(try String(contentsOfFile: file.id, encoding: .utf8), file.tree.text) }
    }

    func testCustomFunctionsAndTaggedMusicAreEvaluatedWithoutFlatteningSource() async throws {
        let lily = try await installation()
        let definitions = #"""
        improv = #(define-music-function (n music) (index? ly:music?)
          #{ << \tag #'printed #music \tag #'played #(skip-of-length music) >> #})
        """#
        let score = #"""
        \score { << \new Staff \removeWithTag #'played \flute \new Devnull \structure >> }
        \score { \new Staff \removeWithTag #'printed \flute \midi {} }
        """#
        let (root, files) = try fixture("flute = \\relative c' { \\time 4/4 \\improv 1 { c4 d e f } | g1 }\nstructure = { \\autoLineBreaksOff s1 \\break | s1 }", definitions: definitions, score: score)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        let migrated = apply(plan, to: files)
        XCTAssertTrue(StructuralEditing.isInterpreted(migrated[0].tree))
        XCTAssertTrue(migrated[1].tree.text.contains("\\improv 1 { c4 d e f }"))
        XCTAssertTrue(migrated[1].tree.text.contains("\\pondsideLayout"))
        XCTAssertTrue(migrated[0].tree.text.contains("s1*4/4 \\break"))
        try unchanged(files)
    }

    func testBarsAddedMidScoreKeepLayoutAnchorsAlignedAndEngrave() async throws {
        let lily = try await installation()
        let definitions = #"""
        improv = #(define-music-function (n music) (index? ly:music?)
          #{ << \tag #'printed #music \tag #'played #(skip-of-length music) >> #})
        """#
        let score = "\\score { << \\new Staff \\removeWithTag #'played \\flute \\new Devnull \\structure >> }"
        let (root, files) = try fixture("flute = \\relative c' { \\time 4/4 \\improv 1 { c4 d e f } | g1 | a1 | b1 }\nstructure = { \\autoLineBreaksOff s1 | s1 \\break | \\mark \\default s1*2 }",
                                        definitions: definitions, score: score)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let migrated = apply(try await StructuralMigration.plan(files: files, root: root.path, installation: lily), to: files)
        XCTAssertFalse(StructuralEditing.layoutRegions(in: migrated[1].tree).isEmpty)
        let changes = try StructuralEditing.insertMeasures(after: "pondsideBarA", count: 2, time: .init(beats: 3, beatType: 4),
                                                           files: migrated, root: root.path)
        let after = migrated.map { file in
            var result = file
            result.tree = file.parse(changes.filter { $0.file == file.id }.flatMap(\.edits).apply(to: file.tree.text))
            return result
        }
        try StructuralEditing.validate(after, root: root.path)
        XCTAssertEqual(StructuralEditing.names(in: after[0].tree),
                       ["pondsideBarA", "pondsideBarE", "pondsideBarF", "pondsideBarB", "pondsideBarC", "pondsideBarD"])
        // The slot that ended at bar A now covers the new bars too.
        XCTAssertTrue(after[1].tree.text.contains("(pondsideBarA . 0) (pondsideBarF . 1)"))
        for file in after { try Data(file.tree.text.utf8).write(to: URL(fileURLWithPath: file.id)) }
        let output = try await ProcessRunner.run(lily.executable, ["-dno-print-pages", "-o", root.deletingLastPathComponent().appendingPathComponent("out").path, root.path])
        XCTAssertEqual(output.status, 0, output.stderrString)
        XCTAssertFalse(output.stderrString.contains("Pondside:"), output.stderrString)
    }

    func testGeneratedFrontMatterLegendIsPreservedWithoutMigration() async throws {
        let lily = try await installation()
        let (root, _) = try fixture("flute = { c'1 | d'1 }\nstructure = { s1 \\break | s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let original = FrontMatter.template([.legend])
        let legend = FrontMatter(original).edits(adding: [.init(id: "excerpt", title: "Excerpt", text: "An independent example",
            example: FrontMatter.example(music: "\\time 3/4 c'2."))]).apply(to: original)
        let front = root.deletingLastPathComponent().appendingPathComponent("front-matter.ily")
        try Data(legend.utf8).write(to: front)
        let text = try String(contentsOf: root, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "\\include \"part.ily\"", with: "\\include \"part.ily\"\n\\include \"front-matter.ily\"").utf8).write(to: root)
        let files = SourceGraph.load(root: root).files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree, entryLanguage: $0.entryLanguage) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        XCTAssertFalse(plan.changes.contains { $0.file == front.path })
        try unchanged(files)
    }

    func testEquivalentFullMeasureRestDurationsPassSemanticValidation() async throws {
        let lily = try await installation()
        let (root, files) = try fixture("flute = { \\time 7/4 R4*7 | \\time 3/4 R4*3 | \\time 4/4 R4*4 }\nstructure = { s4*7 | s4*3 | s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        XCTAssertFalse(plan.changes.isEmpty)
        try unchanged(files)
    }

    func testEntryAcrossMeasureBoundaryPreservesRelativeMusicAndEngraves() async throws {
        let lily = try await installation()
        let (root, files) = try fixture("flute = \\relative c'' { c1 | g1 }\nstructure = { s1 | s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        var migrated = apply(plan, to: files)
        let part = try XCTUnwrap(migrated.firstIndex { $0.id.hasSuffix("part.ily") })
        let rootTree = try XCTUnwrap(migrated.first { $0.id == root.path }?.tree)
        let second = StructuralEditing.measures(in: migrated[part].tree)[1]
        migrated[part].tree = migrated[part].parse([TextEdit(second.body, "g2")].apply(to: migrated[part].tree.text))
        let before = migrated[part].tree
        let anchor = try XCTUnwrap(before.events.indices.first { before.events[$0].kind == .note })
        let next = try XCTUnwrap(StructuralEditing.nextMeasureForEntry(after: anchor, in: before, root: rootTree))
        let edit = try XCTUnwrap(ScoreEditor(before).insert(step: 2, after: anchor, duration: .quarter, insertionAt: next.body.lowerBound))
        let proposed = migrated[part].parse(edit.edits.apply(to: before.text))
        try StructuralEditing.verifyContentEdit(in: migrated[part].id, before: before, proposed: proposed, root: rootTree)
        XCTAssertEqual(before.notes.filter { $0.role == .event }.map(\.absolute),
                       proposed.notes.filter { $0.role == .event && !edit.selectionAnchors.contains($0.name.lowerBound) }.map(\.absolute))
        migrated[part].tree = proposed
        try await StructuralMigration.validate(files: migrated, root: root.path, installation: lily)
        try unchanged(files)
    }

    func testGeneratedMeterAndPageBreakBecomeSharedStructure() async throws {
        let lily = try await installation()
        let definitions = #"""
        section = #(define-music-function (music) (ly:music?)
          #{ \time 5/4 #music \pageBreak #})
        """#
        let (root, files) = try fixture("flute = { \\section { c'1 r4 } | \\time 4/4 d'1 }\nstructure = { s4*5 | s1 }", definitions: definitions)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        let migrated = apply(plan, to: files)
        XCTAssertTrue(migrated[0].tree.text.contains("pondsideBarA = { \\time 5/4 s1*5/4 \\pageBreak }"))
        XCTAssertTrue(migrated[1].tree.text.contains("\\section { c'1 r4 }"))
        XCTAssertTrue(migrated[0].tree.text.contains(definitions))
        try StructuralEditing.validate(migrated, root: root.path)
        try unchanged(files)
    }

    func testGeneratedLayoutSkipsFollowAnEditedMeter() async throws {
        let lily = try await installation()
        let definitions = #"""
        flow = #(define-music-function () () #{ s2 \newSpacingSection s2 #})
        """#
        let (root, files) = try fixture("flute = { c'1 | d'1 }\nstructure = { \\flow \\break | s1 }", definitions: definitions)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        var migrated = apply(plan, to: files)
        XCTAssertTrue(migrated[1].tree.text.contains("\\flow"))
        let edits = try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: migrated, root: root.path)
        for i in migrated.indices {
            migrated[i].tree = migrated[i].parse(edits.filter { $0.file == migrated[i].id }.flatMap(\.edits).apply(to: migrated[i].tree.text))
        }
        try await StructuralMigration.validate(files: migrated, root: root.path, installation: lily)
        try unchanged(files)
    }

    func testUnusedAndReusedMusicHelpersAreNotExtraVoices() async throws {
        let lily = try await installation()
        let (root, files) = try fixture("motif = { c'4 }\nunused = { d'2 }\nflute = { \\motif \\motif \\motif \\motif }\nstructure = { s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        let migrated = apply(plan, to: files)
        XCTAssertTrue(migrated[1].tree.text.contains("motif = { c'4 }"))
        XCTAssertTrue(migrated[1].tree.text.contains("unused = { d'2 }"))
        XCTAssertEqual(StructuralEditing.measures(in: migrated[1].tree).count, 1)
        try unchanged(files)
    }

    func testInvalidSourceAndBadBarChecksFailWithoutWriting() async throws {
        let lily = try await installation()
        for source in ["flute = { \\notACommand c'1 }\nstructure = { s1 }", "flute = { \\time 4/4 c'2 | d'1 }\nstructure = { s1 | s1 }"] {
            let (root, files) = try fixture(source)
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            do {
                _ = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
                XCTFail("Invalid source was accepted")
            } catch let error as StructuralMigration.Failure {
                XCTAssertEqual(error.stage, .checking)
                XCTAssertFalse(error.log.isEmpty)
                XCTAssertTrue(error.description.contains("Make Score Pondside-Ready"))
                XCTAssertFalse(error.log.contains("pondsideMigrationScore"))
                XCTAssertTrue(error.message.contains("part.ily:"))
            }
            try unchanged(files)
        }
    }

    func testCandidateSemanticChangeIsRejected() async throws {
        let lily = try await installation()
        let definitions = #"""
        conditional = #(define-music-function () ()
          (if (eq? #t (ly:parser-lookup 'pondsideInterpreted)) #{ d'1 #} #{ c'1 #}))
        """#
        let (root, files) = try fixture("flute = { \\conditional }\nstructure = { s1 }", definitions: definitions)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        do {
            _ = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
            XCTFail("Changed music was accepted")
        } catch let error as StructuralMigration.Failure {
            XCTAssertEqual(error.stage, .validating)
        }
        try unchanged(files)
    }

    func testReadyProjectCanBeMigratedAgain() async throws {
        let lily = try await installation()
        let (root, files) = try fixture("flute = { c'1 | d'1 }\nstructure = { s1 \\break | s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let first = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        let migrated = apply(first, to: files)
        let again = try await StructuralMigration.plan(files: migrated, root: root.path, installation: lily)
        XCTAssertTrue(again.changes.isEmpty)
        try unchanged(files)
    }

    func testCancellationStopsAnalysisAndLeavesSourceAlone() async throws {
        let (root, files) = try fixture("flute = { c'1 }\nstructure = { s1 }")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let executable = root.deletingLastPathComponent().appendingPathComponent("slow-lilypond")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let lily = LilyPondInstallation(executable: executable.path, resolvedPath: executable.path, version: LilyPondVersion("2.26.0")!, origin: .other)
        let task = Task { try await StructuralMigration.plan(files: files, root: root.path, installation: lily) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation did not stop migration") }
        catch is CancellationError { }
        try unchanged(files)
    }
    func testTremoloAndGeneratedPostEventsKeepTheirInterpretedMeaning() async throws {
        let lily = try await installation()
        let definitions = #"""
        texture = #(define-event-function () () #{ \startTextSpan #})
        """#
        let (root, files) = try fixture("flute = { \\time 5/4 e'2 \\repeat tremolo 8 { gis'32 e'32 } r4 | c'1 r4 }\nstructure = { s2 \\texture s2. \\stopTextSpan | s1*5/4 }", definitions: definitions)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        let migrated = apply(plan, to: files)
        XCTAssertTrue(migrated[1].tree.text.contains("\\repeat tremolo 8"))
        XCTAssertTrue(migrated[1].tree.text.contains("\\texture"))
        try unchanged(files)
    }

}

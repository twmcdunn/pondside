import Foundation
import XCTest
import PondsideCore
import PondsideEngrave

final class StructuralEditingEngravingTests: XCTestCase {
    private func installation() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return lily
    }

    private func apply(_ changes: [StructuralEditing.Change], to files: [StructuralEditing.File]) -> [StructuralEditing.File] {
        files.map { source in
            .init(id: source.id, tree: SyntaxTree(changes.filter { $0.file == source.id }.flatMap(\.edits).apply(to: source.tree.text)))
        }
    }

    private func fixture(_ part: String) -> [StructuralEditing.File] {
        [.init(id: "score.ly", tree: SyntaxTree("\\version \"2.24.3\"\n\\include \"part.ily\"\n\\score { << \\new Staff \\flute \\new Staff \\electronics >> }")),
         .init(id: "part.ily", tree: SyntaxTree(part))]
    }

    private func write(_ files: [StructuralEditing.File], in directory: URL) throws -> URL {
        for source in files { try Data(source.tree.text.utf8).write(to: directory.appendingPathComponent(source.id)) }
        return directory.appendingPathComponent("score.ly")
    }

    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-structure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func breakMoments(_ files: [StructuralEditing.File], lily: LilyPondInstallation, in dir: URL, event: String = "line-break-event") async throws -> [String] {
        let listener = #"""
        \layout {
          \context {
            \Voice
            \consists #(make-engraver
              (listeners
                ((line-break-event engraver event)
                 (format #t "STRUCTURE-BREAK ~a\n"
                   (ly:moment-main (ly:context-current-moment (ly:translator-context engraver)))))))
          }
        }
        """#
        let settings = dir.appendingPathComponent("breaks.ily")
        try Data(listener.replacingOccurrences(of: "(line-break-event", with: "(" + event).utf8).write(to: settings)
        let source = try write(files, in: dir)
        let output = try await ProcessRunner.run(lily.executable, ["-dinclude-settings=\(settings.path)", "-dno-print-pages", "-o", dir.appendingPathComponent("breaks").path, source.path])
        XCTAssertEqual(output.status, 0, output.stderrString)
        return output.stdoutString.components(separatedBy: "STRUCTURE-BREAK ").dropFirst().map { String($0.prefix(while: { !$0.isWhitespace })) }
    }

    func testMigrationPreservesLilyPondPitchesDurationsAndMoments() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = fixture("flute = \\relative c' { \\time 4/4 c4 d e f | g a b c | \\tuplet 3/2 { d4 e f } g2 }\nelectronics = { s1 | s1 | s1 }")
        let before = try await EventDump.run(lily, source: write(files, in: dir))
        let migrated = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        let after = try await EventDump.run(lily, source: write(migrated, in: dir))
        XCTAssertEqual(after.map { "\($0.pitch!) \($0.duration) \($0.moment)" }, before.map { "\($0.pitch!) \($0.duration) \($0.moment)" })
        XCTAssertEqual(after.count, 12)
    }

    func testFiveQuarterBarBreakAndUnmeteredThreeHalfBarStayAligned() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { \\time 7/4 s4*7 | s4*7 | c''''1 r2. }\nelectronics = { s4*7 | R1*7/4 | c'4 s4*6 }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        let first = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        files[1].tree = SyntaxTree([TextEdit(first.body, " e'''2 \\repeat tremolo 8 { gis''32 e''32 } r4 ")].apply(to: files[1].tree.text))
        files = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: first.name, files: files, root: "score.ly"), to: files)
        files = apply(try StructuralEditing.toggleBreak(before: "pondsideBarB", files: files, root: "score.ly"), to: files)
        let second = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first { $0.name == "pondsideBarB" })
        let passage = " e''16 fis'' gis'' b'' cis''' b'' gis'' fis'' e'' fis'' gis'' b'' d''' b'' gis'' fis'' e'' fis'' gis'' c''' d''' c''' gis'' fis'' "
        files[1].tree = SyntaxTree([TextEdit(second.body, passage)].apply(to: files[1].tree.text))
        files = apply(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 2), measure: second.name, files: files, root: "score.ly"), to: files)
        let source = try write(files, in: dir)
        let events = try await EventDump.run(lily, source: source)
        let lastNotes = events.filter { $0.kind == .note && ($0.pitch?.octave == 4 || $0.pitch?.octave == 1 && $0.pitch?.step == 0) }
        XCTAssertEqual(lastNotes.count, 2)
        XCTAssertTrue(lastNotes.allSatisfy { $0.moment == "11/4" })
        XCTAssertTrue(files[0].tree.text.contains("pondsideBarA = { \\time 5/4 s1*5/4 \\break }"))
        XCTAssertFalse(files[1].tree.text.contains("\\break"))
        let output = try await ProcessRunner.run(lily.executable, ["-dbackend=svg", "-o", dir.appendingPathComponent("engraved").path, source.path])
        XCTAssertEqual(output.status, 0, output.stderrString)
        XCTAssertFalse(output.stderrString.contains("barcheck failed"), output.stderrString)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".svg") })
        let breaks = try await breakMoments(files, lily: lily, in: dir)
        XCTAssertEqual(breaks, ["5/4", "5/4"])
    }

    func testFullMeasureRestResizesInOrdinaryLilyPondAndAfterRemovingContract() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { s1 | c''1 }\nelectronics = { \\omit Staff.TimeSignature R1 | d'1 }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        files = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 8), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        let managed = try await EventDump.run(lily, source: write(files, in: dir)).filter { $0.kind == .note }
        XCTAssertEqual(managed.count, 2)
        XCTAssertTrue(managed.allSatisfy { $0.moment == "5/8" })
        let ordinary = apply(try StructuralEditing.removeContract(files, root: "score.ly"), to: files)
        let restored = try await EventDump.run(lily, source: write(ordinary, in: dir)).filter { $0.kind == .note }
        XCTAssertEqual(restored.map(\.moment), managed.map(\.moment))
        XCTAssertEqual(restored.map(\.pitch), managed.map(\.pitch))
    }

    func testHandEditedOverflowFailsInsteadOfShiftingOtherVoices() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { c'1 }\nelectronics = { s1 }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        let first = try XCTUnwrap(StructuralEditing.measures(in: files[1].tree).first)
        files[1].tree = SyntaxTree([TextEdit(first.body, " c'1 d'1 ")].apply(to: files[1].tree.text))
        let source = try write(files, in: dir)
        let output = try await ProcessRunner.run(lily.executable, ["-dno-print-pages", "-o", dir.appendingPathComponent("out").path, source.path])
        XCTAssertNotEqual(output.status, 0)
        XCTAssertTrue(output.stderrString.contains("measure content exceeds its shared length"), output.stderrString)
    }
    func testUncheckingSharedBreaksPreservesTheirPositionAfterPadding() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { c'1 | d'1 }\nelectronics = { s1 | s1 }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        files = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        files = apply(try StructuralEditing.toggleBreak(before: "pondsideBarB", files: files, root: "score.ly"), to: files)
        let shared = try await breakMoments(files, lily: lily, in: dir)
        files = apply(try StructuralEditing.settingBreaks(false, files: files, root: "score.ly"), to: files)
        let local = try await breakMoments(files, lily: lily, in: dir)
        XCTAssertEqual(shared, ["5/4", "5/4"])
        XCTAssertEqual(local, shared)
        files = apply(try StructuralEditing.removeContract(files, root: "score.ly"), to: files)
        let ordinary = try await breakMoments(files, lily: lily, in: dir)
        XCTAssertEqual(ordinary, shared)
    }

    func testFinalBarlineFollowsPaddingAndOptOut() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { c'1 \\bar \"|.\" }\nelectronics = { s1 }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        files = apply(try StructuralEditing.changeMeter(.init(beats: 5, beatType: 4), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        let managed = try await breakMoments(files, lily: lily, in: dir, event: "bar-event")
        XCTAssertEqual(managed, ["5/4"])
        files = apply(try StructuralEditing.removeContract(files, root: "score.ly"), to: files)
        let ordinary = try await breakMoments(files, lily: lily, in: dir, event: "bar-event")
        XCTAssertEqual(ordinary, managed)
    }

    func testManualLayoutTrackWithUnfoldRepeatKeepsBreaksAndSpacingAfterMeterEdit() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let melody = "flute = { \\time 7/4 " + String(repeating: "c'4*7 | ", count: 12) + "\\time 1/4 c'4 | \\time 10/4 c'4*10 }"
        let layout = "electronics = { \\autoLineBreaksOff \\autoPageBreaksOff \\newSpacingSection \\override Score.SpacingSpanner.spacing-increment = #0.75 s4*7 \\newSpacingSection \\revert Score.SpacingSpanner.spacing-increment \\break | \\repeat unfold 11 { s4*7 | } s4 | s4*10 }"
        var files = fixture(melody + "\n" + layout)
        let before = try await EventDump.run(lily, source: write(files, in: dir))
        let spacingBefore = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        let after = try await EventDump.run(lily, source: write(files, in: dir))
        XCTAssertEqual(after.map(\.moment), before.map(\.moment))
        XCTAssertEqual(after.map(\.pitch), before.map(\.pitch))
        let spacingAfter = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        XCTAssertEqual(spacingAfter, spacingBefore)
        XCTAssertEqual(spacingAfter, ["0", "7/4"])
        files = apply(try StructuralEditing.changeMeter(.init(beats: 2, beatType: 1), measure: "pondsideBarA", files: files, root: "score.ly"), to: files)
        let breaks = try await breakMoments(files, lily: lily, in: dir)
        let spacingEdited = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        XCTAssertEqual(breaks, ["2", "2"])
        XCTAssertEqual(spacingEdited, ["0", "2"])
        let rendered = try await EventDump.run(lily, source: write(files, in: dir))
        XCTAssertEqual(rendered[1].moment, "2")
        XCTAssertTrue(files[1].tree.text.contains("\\autoLineBreaksOff \\autoPageBreaksOff"))
    }

    func testInternalLayoutSpacingAnchorScalesWithinItsSharedMeasure() async throws {
        let lily = try await installation()
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files = fixture("flute = { c'1 | d'1 }\nelectronics = { s1*3/2 \\newSpacingSection s2 \\pageBreak }")
        files = apply(try StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true), to: files)
        let initial = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        XCTAssertEqual(initial, ["3/2"])
        files = apply(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 2), measure: "pondsideBarB", files: files, root: "score.ly"), to: files)
        let changed = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        let pages = try await breakMoments(files, lily: lily, in: dir, event: "page-break-event")
        XCTAssertEqual(changed, ["7/4"])
        XCTAssertEqual(pages, ["5/2", "5/2"])
        files = apply(try StructuralEditing.removeContract(files, root: "score.ly"), to: files)
        let ordinary = try await breakMoments(files, lily: lily, in: dir, event: "spacing-section-event")
        XCTAssertEqual(ordinary, changed)
    }

}

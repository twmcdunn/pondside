import Foundation
import XCTest
import PondsideCore
@testable import PondsideTiming

/// A composer's own patch made into a Pondside patch (docs/SUPERCOLLIDER.md).
final class PatchMigrationTests: XCTestCase {
    private func sheet() -> CueSheet { CueSheet(log: TimingLog(rows: []), score: "score.ly") }

    private let custom = """
    // My piece
    s.waitForBoot {
    \tSynthDef(\\mic, { |out| Out.ar(out, SoundIn.ar(0)) }).add;
    \tSynthDef(\\mic2, { |out| Out.ar(out, SoundIn.ar(1)) }).add;
    \t~buf = Buffer.read(s, "birds.wav".resolveRelative);
    };

    (
    ~start = { Routine { 10.wait; Synth(\\default) }.play };
    Pbind(\\dur, 1).play;
    )

    (
    Window("cues").front;
    MIDIdef.noteOn(\\pedal, { ~next.value });
    SystemClock.sched(30, { "half way".postln });
    )

    ~start.value;
    s.record;

    """

    func testAuditSaysWhatIsAutomaticAndWhatIsLeft() {
        let f = PatchMigration.audit(custom)
        let auto = Set(f.filter(\.automatic).map(\.kind))
        let manual = Set(f.filter { !$0.automatic }.map(\.kind))
        XCTAssertEqual(auto, [.notAPatch, .soundIn], "the engine's few names don't collide with ~start, ~buf, ~next")
        XCTAssertEqual(manual, [.loose, .input, .timeline, .gui, .trigger, .clock, .recording])
        XCTAssertEqual(f.first { $0.kind == .soundIn }?.line, 3)
        XCTAssertEqual(f.filter { $0.kind == .loose }.map(\.line), [3], "loose definitions, once per run; not test lines")
    }

    func testMigrationKeepsTheCodeAndLeavesNothingUnreported() {
        let r = PatchMigration.migrate(custom, source: "piece.scd", score: "score.ly", name: "score")
        XCTAssertTrue(r.text.hasPrefix(HandlerSync.patchMarker))
        XCTAssertTrue(r.text.contains("(from piece.scd)"))
        XCTAssertNotNil(PatchContract.mainBlock(in: r.text))
        XCTAssertTrue(r.text.contains("// My piece"), "preserve the composer's comments")
        XCTAssertTrue(r.text.contains("Out.ar(out, In.ar(~live))"))
        XCTAssertTrue(r.text.contains("~buf = Buffer.read"), "nothing of the composer's renamed")
        XCTAssertTrue(r.text.contains("~start = {"))
        XCTAssertTrue(r.text.contains(PatchContract.readyMarker))
        XCTAssertTrue(r.text.contains("/mcp__pondside__sc-patch-migration"))
        for f in r.manual {
            let line = r.text.components(separatedBy: "\n")[f.line! - 1]
            XCTAssertTrue(line.contains(PatchMigration.note), "\(f.kind) at \(line)")
        }
        XCTAssertEqual(PatchMigration.audit(r.text), [], "marked lines aren't reported again")
    }

    func testQuarkHandlersBecomeCueHandlersInTheCueSection() {
        let quark = """
        p = Pondside("/x", "score");

        // @pondside cue cue-1 · bar 1 beat 1 · 0.000 s
        p.on(\\cue1, { |cue|
        \tSynth(\\default);
        });
        // @pondside end cue-1

        p.play;

        """
        XCTAssertTrue(PatchMigration.audit(quark).contains { $0.kind == .quark })
        let r = PatchMigration.migrate(quark, source: "score.scd", score: "score.ly", name: "score")
        XCTAssertTrue(r.text.contains("\(HandlerSync.cuesAnchor)\n// @pondside cue cue-1 · bar 1 beat 1 · 0.000 s\n~cue[\\cue1] = { |cue|\n\tSynth(\\default);\n};"), r.text)
        XCTAssertTrue(r.text.contains("// p = Pondside(\"/x\", \"score\");"))
        XCTAssertFalse(r.text.contains("p.on("))
        XCTAssertEqual(r.manual, [])
    }

    func testAStarterNobodyTouchedDoesNotHideACustomPatch() {
        let timing = "PONDSIDE-TIMING\t0\t1\t@0\ttempo\t60\nPONDSIDE-TIMING\t0\t1\t@0\ttext\tcue 1\n"
        let starter = HandlerSync.patchStarter(CueSheet(log: TimingLog(parsing: timing, prefix: "PONDSIDE-TIMING\t"), score: "score.ly"), name: "score")
        XCTAssertTrue(starter.contains("~cue[\\cue1]"))
        XCTAssertTrue(PatchMigration.isUntouchedStarter(starter))
        XCTAssertFalse(PatchMigration.isUntouchedStarter(starter.replacingOccurrences(
            of: HandlerSync.cuesAnchor, with: "SynthDef(\\a, { }).add;\n" + HandlerSync.cuesAnchor)))
        XCTAssertFalse(PatchMigration.isUntouchedStarter(starter.replacingOccurrences(
            of: "~cue[\\cue1] = { |cue|\n\n};", with: "~cue[\\cue1] = { |cue|\n\tSynth(\\default);\n};")))
        XCTAssertFalse(PatchMigration.isUntouchedStarter(custom))
    }

    func testLiveOnlyBlocksAndPondsidesOwnCodeAreNotReported() {
        let patch = HandlerSync.patchStarter(sheet(), name: "score")
            + "\n(\n\(HandlerSync.liveOnlyMarker)\nWindow(\"x\").front;\nMIDIdef.noteOn(\\p, { ~triggerCue.() });\n)\n"
        XCTAssertEqual(PatchMigration.audit(patch), [])
    }

    func testFilesThePatchLoadsAreAuditedAndMarked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-deps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("deps"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let patch = dir.appendingPathComponent("score.scd")
        let starter = HandlerSync.patchStarter(sheet(), name: "score")
            .replacingOccurrences(of: HandlerSync.cuesAnchor, with: "\"deps/cues.scd\".resolveRelative.load;\n" + HandlerSync.cuesAnchor)
        try Data(starter.utf8).write(to: patch)
        try Data("~cues = [];\nfork({ 1.wait }, SystemClock);\n~loadCueTimes = { \"export_piece.sh\".unixCmd };\n".utf8)
            .write(to: dir.appendingPathComponent("deps/cues.scd"))
        let f = PatchMigration.auditDependencies(of: patch)
        XCTAssertEqual(f.map(\.kind), [.clock, .pipeline], "~cues isn't the engine's any more")
        XCTAssertEqual(Set(f.compactMap(\.file)), ["deps/cues.scd"])
        let (r, _, _) = try PatchMigration.write(score: dir.appendingPathComponent("score.ly"), source: patch, target: patch, sheet: nil)
        XCTAssertEqual(r.manual.filter { $0.file == "deps/cues.scd" }.count, 2)
        XCTAssertEqual(PatchMigration.allMarks(patch: patch).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("deps/cues.before-pondside.scd").path))
        XCTAssertEqual(PatchMigration.auditDependencies(of: patch), [], "marked lines aren't reported again")
    }

    func testAnUntouchedStarterAloneIsNotOffered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-starter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let score = dir.appendingPathComponent("invention.ly")
        try Data(HandlerSync.patchStarter(sheet(), name: "invention").utf8)
            .write(to: dir.appendingPathComponent("invention.scd"))
        XCTAssertNil(PatchMigration.candidate(score: score))
        try Data("SynthDef(\\a, { }).add;\n".utf8).write(to: dir.appendingPathComponent("mine.scd"))
        XCTAssertEqual(PatchMigration.candidate(score: score)?.source.lastPathComponent, "mine.scd")
    }

    func testTheRefactorMovesThePatchAndWhatItUsesIntoPatch() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pondside-move-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("dependencies"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let score = dir.appendingPathComponent("score.ly")
        try Data("{ c1 }\n".utf8).write(to: score)
        try Data("~x = 1;\n".utf8).write(to: dir.appendingPathComponent("dependencies/a.scd"))
        try Data("RIFF".utf8).write(to: dir.appendingPathComponent("score.wav"))
        let piece = dir.appendingPathComponent("piece.scd")
        try Data("""
        (
        "dependencies/a.scd".loadRelative;
        ~b = Buffer.read(s, "../elsewhere.wav".resolveRelative);
        ~notes = "notes.ly".resolveRelative;
        )

        """.utf8).write(to: piece)
        let c = try XCTUnwrap(PatchMigration.candidate(score: score))
        XCTAssertEqual(c.source.resolvingSymlinksInPath().path, piece.resolvingSymlinksInPath().path)
        XCTAssertEqual(c.target.resolvingSymlinksInPath().path, dir.appendingPathComponent("patch/score.scd").resolvingSymlinksInPath().path)
        let (_, _, moved) = try PatchMigration.write(score: score, source: c.source, target: c.target, sheet: nil)
        XCTAssertEqual(moved, ["dependencies → patch/dependencies", "piece.scd → patch/score.scd", "score.wav → renders/"])
        let text = try String(contentsOf: c.target, encoding: .utf8)
        XCTAssertTrue(text.contains("\"dependencies/a.scd\".loadRelative"), "it moved along: the same path")
        XCTAssertTrue(text.contains("\"../../elsewhere.wav\".resolveRelative"), "outside the folder: one more ../")
        XCTAssertTrue(text.contains("\"../notes.ly\".resolveRelative"), "a score file stays in the root")
        for kept in ["patch/dependencies/a.scd", "patch/dependencies/pondside.scd", "patch/piece.before-pondside.scd", "renders/score.wav", "score.ly"] {
            XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(kept).path), kept)
        }
        XCTAssertFalse(fm.fileExists(atPath: piece.path))
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("dependencies").path))
    }

    func testTheModeAndTestLinesAreNotFindings() {
        let patch = HandlerSync.patchStarter(sheet(), name: "score") + "~pb1.set(\\amp, 0.5);\n~rhtSets.(true);\n"
        XCTAssertEqual(PatchMigration.audit(patch), [])
    }

    func testEngineNamesAreEveryNameTheEngineAssigns() {
        let body = HandlerSync.engine(name: "score")
        let assigned = Set(SCLexer.tokenize(body).filter { $0.kind == .environment }.map { t -> String in
            let u = Array(body.utf16)
            return String(decoding: u[(t.range.lowerBound + 1)..<t.range.upperBound], as: UTF16.self)
        })
        XCTAssertEqual(assigned.subtracting(PatchMigration.engineNames), [])
    }
}

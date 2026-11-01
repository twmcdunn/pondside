import Foundation
import XCTest
@testable import PondsideTiming

final class HandlerSyncTests: XCTestCase {
    func sheet(_ cues: [(String, Rational)]) -> CueSheet {
        var text = "PONDSIDE-TIMING\t0\t1\t@0\tmeter\t4/4\nPONDSIDE-TIMING\t0\t1\t@0\ttempo\t60\n"
        for (name, m) in cues {
            let bar = Int((m.doubleValue).rounded(.down)) + 1
            let pos = m - Rational(bar - 1)
            text += "PONDSIDE-TIMING\t\(m)\t\(bar)\t@\(pos)\ttext\tcue \(name)\n"
        }
        return CueSheet(log: TimingLog(parsing: text, prefix: "PONDSIDE-TIMING\t"), score: "piece.ly")
    }

    func testStarterHasAStubPerCue() {
        let s = HandlerSync.starter(sheet([("1", Rational(0)), ("2", Rational(1))]), projectPath: "~/scores/piece", name: "score")
        XCTAssertTrue(s.contains("p = Pondside(\"~/scores/piece\", \"score\");"))
        XCTAssertTrue(s.contains("// @pondside cue cue-1 · bar 1 beat 1 · 0.000 s\np.on(\\cue1, { |cue|"))
        XCTAssertTrue(s.contains("// @pondside cue cue-2 · bar 2 beat 1 · 4.000 s"))
        XCTAssertEqual(HandlerSync.blocks(s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).count, 2)
    }

    /// The law: Pondside never modifies code inside a handler body.
    func testBodiesSurviveEveryChange() {
        let v1 = sheet([("1", Rational(0)), ("2", Rational(1))])
        var file = HandlerSync.starter(v1, projectPath: "p")
        let mine = "\t~verb.set(\\mix, 0.4);  // composer's code"
        file = file.replacingOccurrences(of: "\t// cue 2 at moment 1\n", with: "\t// cue 2 at moment 1\n\(mine)\n")

        // Cue 2 moves, cue 3 appears between 1 and 2.
        let v2 = sheet([("1", Rational(0)), ("3", Rational(1, 2)), ("2", Rational(3, 2))])
        let (moved, r2) = HandlerSync.sync(file, with: v2)
        XCTAssertEqual(r2.added, ["cue-3"])
        XCTAssertEqual(r2.moved, ["cue-2"])
        XCTAssertTrue(moved.contains(mine))
        XCTAssertTrue(moved.contains("// @pondside cue cue-2 · bar 2 beat 3 · 6.000 s"))
        let order = HandlerSync.blocks(moved.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)).map(\.id)
        XCTAssertEqual(order, ["cue-1", "cue-3", "cue-2"])

        // Cue 2 leaves the score: commented out, not deleted.
        let v3 = sheet([("1", Rational(0)), ("3", Rational(1, 2))])
        let (orphaned, r3) = HandlerSync.sync(moved, with: v3)
        XCTAssertEqual(r3.orphaned, ["cue-2"])
        XCTAssertTrue(orphaned.contains("//~ " + mine))
        XCTAssertFalse(orphaned.contains("\n" + mine))

        // ...and comes back exactly.
        let (restored, r4) = HandlerSync.sync(orphaned, with: v2)
        XCTAssertEqual(r4.restored, ["cue-2"])
        XCTAssertEqual(restored, moved)

        // Syncing twice changes nothing.
        let (again, r5) = HandlerSync.sync(restored, with: v2)
        XCTAssertEqual(again, restored)
        XCTAssertEqual(r5, HandlerSync.Report())
    }

    func testCodeOutsideBlocksIsUntouched() {
        let file = "s.boot;\n// my notes\n~x = 1;\n"
        let (out, report) = HandlerSync.sync(file, with: sheet([("A", Rational(0))]))
        XCTAssertTrue(out.hasPrefix("s.boot;\n// my notes\n~x = 1;\n"))
        XCTAssertEqual(report.added, ["cue-A"])
        XCTAssertTrue(out.contains("p.on(\\a, { |cue|"))
    }

    func testANewPatchHasTheEngineAndOneStubPerCueInsideTheCueBlock() {
        let s = HandlerSync.patchStarter(sheet([("1", Rational(0)), ("2", Rational(1))]), name: "quartet")
        XCTAssertTrue(s.hasPrefix(HandlerSync.patchMarker))
        XCTAssertTrue(s.contains("~mode = \\mockup;"))
        XCTAssertTrue(s.contains("\"dependencies/pondside.scd\".loadRelative;"))
        XCTAssertTrue(s.contains("~triggerCue.();      // cue 1 starts the piece"))
        XCTAssertTrue(s.contains("~stop.();"))
        XCTAssertFalse(s.contains("SoundIn"), "the engine is in its own file")
        let engine = HandlerSync.engine(name: "quartet")
        XCTAssertTrue(engine.contains("SoundIn.ar(0)"))
        XCTAssertTrue(engine.contains("~triggerCue = { |cue|"))
        XCTAssertTrue(engine.contains("e[\\renders] = here +/+ \"../../renders\";\ne[\\name] = \"quartet\";"))
        XCTAssertTrue(s.contains("\(HandlerSync.cuesAnchor)\n// @pondside cue cue-1 · bar 1 beat 1 · 0.000 s\n~cue[\\cue1] = { |cue|\n\n};\n// @pondside end cue-1\n"))
        XCTAssertTrue(s.contains("// @pondside end cue-2\n\n)\n"))
    }

    func testAPatchGainsStubsInItsOwnStyleEvenWhenItHasNone() {
        let empty = HandlerSync.patchStarter(sheet([]), name: "n")
        let (out, report) = HandlerSync.sync(empty, with: sheet([("3", Rational(2))]))
        XCTAssertEqual(report.added, ["cue-3"])
        XCTAssertTrue(out.contains("\(HandlerSync.cuesAnchor)\n// @pondside cue cue-3 · bar 3 beat 1 · 8.000 s\n~cue[\\cue3] = { |cue|"), out)
        XCTAssertFalse(out.contains("p.on("))
        XCTAssertFalse(out.contains("Pondside(\""), "a patch needs no quark")
    }

    func testAQuarkFileWithoutPGetsOne() {
        let (out, _) = HandlerSync.sync("// mine\n{ SinOsc.ar }.play;\n", with: sheet([("1", Rational(0))]), quark: ("/d", "score"))
        XCTAssertTrue(out.hasPrefix("// mine\np = Pondside(\"/d\", \"score\");\n\n{ SinOsc.ar }.play;"), out)
        XCTAssertTrue(out.contains("p.on(\\cue1, { |cue|"))
        // Present already: left alone.
        let (again, _) = HandlerSync.sync(out, with: sheet([("1", Rational(0))]), quark: ("/d", "score"))
        XCTAssertEqual(again.components(separatedBy: "Pondside(").count, 2)
    }

    /// A stub after a handler written without the markers would replace it.
    func testAHandlerWrittenByHandGetsNoStub() {
        let patch = HandlerSync.patchStarter(sheet([]), name: "n")
            .replacingOccurrences(of: HandlerSync.cuesAnchor, with: "\(HandlerSync.cuesAnchor)\n~cue[\\cue1] = { |cue| \"mine\".postln };")
        let (out, report) = HandlerSync.sync(patch, with: sheet([("1", Rational(0)), ("2", Rational(1))]))
        XCTAssertEqual(report.added, ["cue-2"])
        XCTAssertEqual(out.components(separatedBy: "~cue[\\cue1]").count, 2, out)
        let (quark, _) = HandlerSync.sync("p.on(\\cue1, { });\n// p.on(\\cue2, { });\n", with: sheet([("1", Rational(0)), ("2", Rational(1))]))
        XCTAssertFalse(quark.contains("// @pondside cue cue-1 "))
        XCTAssertTrue(quark.contains("// @pondside cue cue-2 "), "a commented-out handler doesn't count")
    }
}

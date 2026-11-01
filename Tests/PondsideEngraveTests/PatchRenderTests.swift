import Foundation
import XCTest
import PondsideCore
import PondsideTiming
@testable import PondsideEngrave

/// `pondside mix`: a Pondside patch rendered offline in mockup mode, the
/// score with its electronics.
final class PatchRenderTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mix-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Two seconds of stereo 16-bit silence: a mockup with nothing in it.
    private func silentWAV(_ url: URL, seconds: Int = 2, rate: Int = 48000) throws {
        let bytes = seconds * rate * 4
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func u16(_ v: Int) { d.append(contentsOf: (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: bytes))
        try d.write(to: url)
    }

    func testOnlyAPondsidePatchIsRendered() throws {
        let dir = try temp()
        let score = dir.appendingPathComponent("quartet.ly")
        let scd = dir.appendingPathComponent("patch/quartet.scd")
        try FileManager.default.createDirectory(at: scd.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ SinOsc.ar }.play;\n".utf8).write(to: scd)
        XCTAssertNil(PatchRender.patch(for: score))
        try Data(HandlerSync.patchStarter(CueSheet(log: TimingLog(rows: []), score: "quartet.ly"), name: "quartet").utf8).write(to: scd)
        XCTAssertEqual(PatchRender.patch(for: score), scd)
        XCTAssertEqual(PatchRender.output(for: score).path, dir.appendingPathComponent("renders/quartet.mix.wav").path)
    }

    func testTheScriptRunsTheBlocksButNotTheLooseLines() {
        let patch = "(\n~a = 1;\n)\n~triggerCue.();\n(\n~b = 2;\n)\n"
        XCTAssertEqual(PatchRender.blocks(in: patch), ["\n~a = 1;\n", "\n~b = 2;\n"])
        let script = PatchRender.script(patch: patch, wav: URL(fileURLWithPath: "/m.wav"), out: URL(fileURLWithPath: "/o.wav"),
                                        osc: URL(fileURLWithPath: "/s.osc"))
        XCTAssertTrue(script.contains("\"\\n~a = 1;\\n\",\n\"\\n~b = 2;\\n\"") || script.contains("\"\n~a = 1;\n\",\n\"\n~b = 2;\n\""), script)
        XCTAssertTrue(script.contains("~mode = \\mockup;"))
        XCTAssertTrue(script.contains("~triggerCue.();   // cue 1 starts the piece"))
    }

    /// A cue's synths, before and after it waits, are in the mix; the
    /// silent mockup alone is not.
    func testACueIsHeardAtItsTime() async throws {
        guard let sclang = SuperColliderToolchain.findSclang() else { throw XCTSkip("sclang not installed") }
        let dir = try temp()
        let renders = dir.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at: renders, withIntermediateDirectories: true)
        try silentWAV(renders.appendingPathComponent("p.wav"))
        try Data("0.500\t1\tcue 1\n".utf8).write(to: renders.appendingPathComponent("p.cues"))
        var text = HandlerSync.patchStarter(CueSheet(log: TimingLog(rows: []), score: "p.ly"), name: "p")
        text = text.replacingOccurrences(of: HandlerSync.cuesAnchor, with: """
        \(HandlerSync.cuesAnchor)
        SynthDef(\\blip, { Out.ar(0, SinOsc.ar(1000) * EnvGen.kr(Env.linen(0, 0.1, 0), doneAction: 2) * 0.5 ! 2) }).add;
        ~cue[\\cue1] = { |cue| Synth(\\blip); s.sync; 1.wait; fork { Synth(\\blip) } };
        """)
        let patch = dir.appendingPathComponent("patch/p.scd")
        try FileManager.default.createDirectory(at: patch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: patch)
        try PatchMigration.ensureEngine(patch: patch, name: "p")
        let out = renders.appendingPathComponent("p.mix.wav")
        try await PatchRender.render(sclang: sclang, patch: patch, wav: renders.appendingPathComponent("p.wav"), out: out, timeout: 120)
        let info = try XCTUnwrap(WAVInfo(try Data(contentsOf: out)))
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.seconds, 7, accuracy: 0.05, "the mockup's length plus the tail")
        XCTAssertFalse(info.isSilent)
    }
}

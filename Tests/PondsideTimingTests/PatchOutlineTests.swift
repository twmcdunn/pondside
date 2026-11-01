import Foundation
import XCTest
@testable import PondsideTiming

/// The patch doc's outline is built from the code, and its notes survive
/// rebuilds, going stale when the code they describe changes.
final class PatchOutlineTests: XCTestCase {
    static let patch = """
    // @pondside patch for s.ly.
    (
    ~mode = \\mockup;
    "dependencies/pondside.scd".loadRelative;
    )

    (
    SynthDef(\\grain, { |out = 0, freq = 440, amp = 0.1|
    \tOut.ar(out, SinOsc.ar(freq) * amp);
    }).add;
    ~verbBus = Bus.audio(s, 2);
    ~cloud = Pbind(
    \t\\instrument, \\grain,
    \t\\dur, 0.1
    );
    ~swell = { |secs = 4| Line.kr(0, 1, secs) };
    Pdef(\\drone, Pbind(\\instrument, \\grain, \\dur, 2));
    )

    (
    // @pondside cues
    // @pondside cue cue-12 · bar 42 beat 1 · 133.333 s
    ~cue[\\cue12] = { |cue|
    \t~player = ~cloud.play;
    \t~verbBus.index.postln;
    };
    // @pondside end cue-12
    )

    (
    // @pondside live
    MIDIdef.noteOn(\\pedal, { ~triggerCue.() });
    )
    """

    func testTheOutlineNamesEachDefinitionWithItsLines() throws {
        let items = PatchOutline.items(in: Self.patch, file: "s.scd")
        let keys = items.map(\.key)
        XCTAssertEqual(keys, ["synthdef \\grain", "bus ~verbBus", "pattern ~cloud", "function ~swell", "pdef \\drone",
                              "cue cue-12", "live block 30"], "\(items.map(\.line))")
        let grain = try XCTUnwrap(items.first { $0.name == "\\grain" })
        XCTAssertEqual(grain.fromLine, 8)
        XCTAssertEqual(grain.toLine, 10)
        XCTAssertEqual(grain.summary, "|out = 0, freq = 440, amp = 0.1|")
        let cloud = try XCTUnwrap(items.first { $0.name == "~cloud" })
        XCTAssertEqual(cloud.fromLine...cloud.toLine, 12...15)
        XCTAssertEqual(items.first { $0.name == "~swell" }?.summary, "|secs = 4|")
        let cue = try XCTUnwrap(items.first { $0.kind == "cue" })
        XCTAssertEqual(cue.summary, "bar 42 beat 1 · 133.333 s")
        XCTAssertEqual(cue.fromLine, 22)
        XCTAssertEqual(cue.toLine, 27)
        // What the handler touches, for patch_context.
        let outline = PatchOutline(items: items)
        XCTAssertEqual(outline.resolve(cue.references).map(\.key), ["bus ~verbBus", "pattern ~cloud"])
        // An assignment inside a handler isn't an item of its own.
        XCTAssertFalse(keys.contains { $0.contains("~player") })
    }

    func testTheHashIgnoresReindenting() {
        XCTAssertEqual(PatchOutline.hash("a = 1;\n\tb"), PatchOutline.hash("a  =  1;\n    b"))
        XCTAssertNotEqual(PatchOutline.hash("a = 1;"), PatchOutline.hash("a = 2;"))
    }

    func testNotesAreKeptAndGoStaleWhenTheCodeChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let patch = dir.appendingPathComponent("s.scd")
        try Self.patch.write(to: patch, atomically: true, encoding: .utf8)

        XCTAssertEqual(try PatchDoc.setNote(patch: patch, key: "~cloud", text: "The flute's halo: starts at cue 12."), "pattern ~cloud")
        try PatchDoc.setNote(patch: patch, key: "overview", text: "One layer of grains, one reverb bus.")
        XCTAssertThrowsError(try PatchDoc.setNote(patch: patch, key: "~nothing", text: "x"))
        var doc = try PatchDoc.update(patch: patch)
        XCTAssertTrue(doc.text.contains("## pattern ~cloud\n`s.scd:12-15` · ~cloud = Pbind("), doc.text)
        XCTAssertTrue(doc.text.contains("The flute's halo"))
        XCTAssertTrue(doc.stale.isEmpty)

        // The pattern changes (and moves down a line): its note goes stale, the overview doesn't.
        try Self.patch.replacingOccurrences(of: "\\dur, 0.1", with: "\\dur, 0.05")
            .replacingOccurrences(of: "~verbBus = Bus.audio(s, 2);", with: "~verbBus = Bus.audio(s, 2);\n// buses")
            .write(to: patch, atomically: true, encoding: .utf8)
        doc = try PatchDoc.update(patch: patch)
        XCTAssertEqual(doc.stale, ["pattern ~cloud"])
        XCTAssertTrue(doc.text.contains("## pattern ~cloud\n`s.scd:13-16` · ~cloud = Pbind(\n**Stale:**"), doc.text)
        XCTAssertTrue(doc.text.contains("One layer of grains"))
        // Rewriting the note clears it; the hand-edited file's notes survive a rebuild.
        try PatchDoc.setNote(patch: patch, key: "pattern ~cloud", text: "Denser now.")
        XCTAssertEqual(try PatchDoc.update(patch: patch).stale, [])
        let notes = PatchDoc.notes(in: try String(contentsOf: PatchDoc.url(patch: patch), encoding: .utf8))
        XCTAssertEqual(notes["pattern ~cloud"]?.text, "Denser now.")
        XCTAssertEqual(notes["overview"]?.text, "One layer of grains, one reverb bus.")

        // An item that goes keeps its note, marked.
        try Self.patch.replacingOccurrences(of: "~cloud", with: "~mist").write(to: patch, atomically: true, encoding: .utf8)
        doc = try PatchDoc.update(patch: patch)
        XCTAssertTrue(doc.text.contains("## pattern ~cloud\n*No longer in the patch.*"), doc.text)
    }

    func testTheLexiconIncludeIsLoadedAfterTheEngine() {
        let with = SCLexiconInclude.withLoadLine(Self.patch)
        let lines = with.components(separatedBy: "\n")
        XCTAssertTrue(lines[4].hasPrefix(SCLexiconInclude.loadLine), lines[4])
        XCTAssertEqual(SCLexiconInclude.withLoadLine(with), with)
        XCTAssertEqual(SCLexiconInclude.ids(in: "x\n// @pondside sc-lexicon glide cloud\n"), ["glide", "cloud"])
    }
}

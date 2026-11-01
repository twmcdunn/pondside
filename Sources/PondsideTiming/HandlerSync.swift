import Foundation
/// Keeps a SuperCollider file of cue handlers in step with the score.
///
/// Each cue owns a block between marker comments. In a patch Pondside
/// started (`patchStarter`, marked `// @pondside patch`):
///
///     // @pondside cue cue-12 · bar 42 beat 1 · 133.333 s
///     ~cue[\cue12] = { |cue|
///         … the composer's code …
///     };
///     // @pondside end cue-12
///
/// and in a file for the Pondside quark, `p.on(\cue12, { |cue| … });`.
///
/// Pondside rewrites only the header line (where and when the cue is).
/// Everything between the header and the end marker belongs to the
/// composer and is never changed — except that when a cue leaves the score
/// its block is commented out line by line (`//~ `), and restored exactly
/// if the cue comes back. New cues get empty stubs in score order.
public enum HandlerSync {
    public static let patchMarker = "// @pondside patch"
    /// The line in a patch after which the first cue's stub goes.
    public static let cuesAnchor = "// @pondside cues"
    public static let headerPrefix = "// @pondside cue "
    public static let orphanPrefix = "// @pondside orphan "
    public static let endPrefix = "// @pondside end "
    /// A block whose first line is this comment runs live only (windows,
    /// MIDI and OSC setup): the offline render skips it.
    public static let liveOnlyMarker = "// @pondside live"
    static let commented = "//~ "

    /// The first version of the file. `projectPath` and `name` say where
    /// the quark finds `<name>.cues` and `<name>.wav`: `pondside mockup`
    /// writes them beside the score, named after it.
    public static func starter(_ sheet: CueSheet, projectPath: String, name: String = "piece") -> String {
        var out = """
        // Cue handlers for \(sheet.score), kept in sync by Pondside.
        // Write anything inside a handler: Pondside only adds stubs for new cues,
        // updates the comment line above each handler, and comments out
        // handlers whose cue has left the score (restoring them if it returns).
        p = Pondside("\(projectPath)", "\(name)");


        """
        for cue in sheet.cues { out += stub(cue) + "\n" }
        out += "// p.play;   // or p.play(from: \"12:1\")\n"
        return out
    }

    /// Where a score's SuperCollider files live: the patch in `patch/`, the
    /// engine and the patch's own dependencies in `patch/dependencies/`, and
    /// Pondside's renders (mockup, cue times, mix) in `renders/`.
    public enum Layout {
        public static func patch(score: String, name: String) -> String { score + "/patch/\(name).scd" }
        public static let engineFile = "dependencies/pondside.scd"
        public static let renders = "renders"

        static func render(_ score: URL, _ ext: String) -> URL {
            score.deletingLastPathComponent().appendingPathComponent(renders)
                .appendingPathComponent(score.deletingPathExtension().lastPathComponent + "." + ext)
        }
        /// `renders/<name>.wav`: the score's mockup.
        public static func mockup(score: URL) -> URL { render(score, "wav") }
        /// `renders/<name>.cues`: its cue times.
        public static func cues(score: URL) -> URL { render(score, "cues") }
        /// `renders/<name>.mix.wav`: the patch rendered against the mockup.
        public static func mix(score: URL) -> URL { render(score, "mix.wav") }
    }

    /// A new patch: the mode and the engine's load line, a place for sounds
    /// and effects, a stub per cue, and how to run it. Everything else is in
    /// the engine (`engine(name:)`, `dependencies/pondside.scd`).
    public static func patchStarter(_ sheet: CueSheet, name: String) -> String {
        var out = """
        \(patchMarker) for \(sheet.score). Run each ( … ) block with ⌘↩, a line with ⇧↩.
        \(engineIntro(name: name))

        \(setupBlock)

        // Sounds and effects: SynthDefs, buffers, effects (on the performer: In.ar(~live)).
        (

        )

        // Cues: ~cue[\\cueN] runs at cue N, as a routine (wait, fork and patterns work).
        (
        \(cuesAnchor)

        """
        for cue in sheet.cues { out += patchStub(cue) + "\n" }
        out += """
        )

        \(runLines)
        """
        return out
    }

    static func engineIntro(name: String) -> String {
        """
        // The engine (\(Layout.engineFile), written by Pondside) plays the score's mockup
        // (../renders/\(name).wav) or the mic, and fires the cues. After every engraving Pondside
        // adds a stub for each new cue and renders this patch into ../renders/\(name).mix.wav (⌘⌥P).
        """
    }

    /// The first block of a patch: the mode, and the engine.
    public static let setupBlock = """
    (
    ~mode = \\mockup;   // \\mockup: the mockup plays and the cues fire on time; \\live: the mic, you fire each cue
    "\(Layout.engineFile)".loadRelative;
    )
    """

    /// How a patch is run, at its end.
    public static let runLines = """
    // Run
    ~triggerCue.();      // cue 1 starts the piece; after that, each call is the next cue
    ~triggerCue.(12);    // start at (or jump to) cue 12: the cues before it run at once
    ~stop.();

    """

    /// The engine, `patch/dependencies/pondside.scd`: Pondside writes it and
    /// keeps it current; nothing in it is the composer's. Its names are few
    /// (`~mode`, `~cue`, `~live`, `~triggerCue`, `~stop`); the rest is in
    /// `~pondside`, a dictionary read by key, so nothing collides.
    public static func engine(name: String) -> String {
        """
        // Pondside's engine for \(name). Pondside writes this file and keeps it current: don't edit it.
        // The patch loads it with "\(Layout.engineFile)".loadRelative; then:
        //   ~mode              \\mockup: the mockup (../renders/\(name).wav) is the live signal and the
        //                      cues fire on time; \\live: the mic, SoundIn.ar(0), and you fire each cue
        //   ~cue[\\cue12] = { |cue| … };   what happens at cue 12 (a routine: wait, fork, patterns)
        //   ~live              the live signal's bus: effects on the performer read In.ar(~live)
        //   ~triggerCue.()     cue 1 starts the piece; after that, the next cue
        //   ~triggerCue.(12)   start at (or jump to) cue 12: the cues before it run at once
        //   ~stop.()           stops the piece, and the routines and patterns its cues started
        // A block whose first line is \(liveOnlyMarker) runs live only: Pondside's mix skips it.
        (
        var here = thisProcess.nowExecutingPath !? { |p| p.dirname } ? "", e;
        ~pondside = ~pondside ?? { IdentityDictionary.new };
        e = ~pondside;
        e[\\renders] = here +/+ "../../renders";
        e[\\name] = "\(name)";
        ~mode = ~mode ? \\mockup;
        ~cue = ~cue ? ();
        ~live = ~live ? Bus.audio(s, 1);
        SynthDef(\\pondsideMockup, { |buf, live, start = 0|
        \tvar sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf), startPos: start * BufSampleRate.kr(buf), doneAction: 2);
        \tOut.ar(0, sig);
        \tOut.ar(live, sig.sum * 0.5);
        }).add;
        SynthDef(\\pondsideMic, { |live| Out.ar(live, SoundIn.ar(0)) }).add;
        // "12" -> \\cue12, "FxSwell" -> \\fxSwell, as Pondside names the handlers
        e[\\handler] = { |name|
        \tvar n = name.collect { |c| if(c.isAlphaNum) { c } { $_ } };
        \tif(n[0].isDecDigit) { ("cue" ++ n).asSymbol } { n.copy.put(0, n[0].toLower).asSymbol }
        };
        // the cue list, [(time, bar, name, handler), …], from ../renders/<name>.cues
        e[\\cues] = {
        \tvar path = e[\\renders] +/+ e[\\name] ++ ".cues";
        \tif(File.exists(path)) {
        \t\tFile.readAllString(path).split($\\n).reject(_.isEmpty).collect { |l|
        \t\t\tvar f = l.split($\\t), n = f[2].replace("cue ", "");
        \t\t\t(time: f[0].asFloat, bar: f[1].asInteger, name: n, handler: e[\\handler].(n))
        \t\t}
        \t} { "no %: engrave the score in Pondside first".format(path).warn; [] }
        };
        e[\\fire] = { |c| ("cue " ++ c.name).postln; ~cue[c.handler] !? { |f| f.value(c) } };
        e[\\fireNow] = { |c| fork { e[\\fire].(c) } };   // a routine: a cue may wait
        // plays from `from` seconds on the score's clock (beats = seconds); in mockup mode the
        // cues from there on fire on time
        e[\\play] = { |from|
        \te[\\clock] = ~renderClock ?? { TempoClock(1, from).permanent_(true) };   // Pondside's mix brings its own
        \te[\\mainClock] = TempoClock.default;
        \tTempoClock.default = e[\\clock];         // fork/wait and patterns in cues run on it
        \tCmdPeriod.doOnce { e[\\src] = nil; ~stop.() };
        \te[\\src] = if(~mode == \\live) { Synth(\\pondsideMic, [\\live, ~live]) }
        \t\t{ Synth(\\pondsideMockup, [\\buf, e[\\buf], \\live, ~live, \\start, from]) };
        \tif(~mode == \\mockup) { e[\\list].do { |c, i| if(c.time >= from) {
        \t\te[\\clock].schedAbs(c.time, { e[\\index] = max(e[\\index], i + 1); e[\\fireNow].(c); nil }) } } };
        \t"% from % s".format(~mode, from).postln;
        };
        // starts the piece at cue i (0: from the start): the cues before it run at once
        e[\\start] = { |i|
        \t~stop.();
        \te[\\list] = e[\\cues].value;
        \tfork {
        \t\tvar from = if(i > 0 and: { i < e[\\list].size }) { e[\\list][i].time } { 0 };
        \t\te[\\buf] !? { e[\\buf].free };
        \t\te[\\buf] = if(~mode == \\mockup) { Buffer.read(s, e[\\renders] +/+ e[\\name] ++ ".wav") };
        \t\ts.sync;
        \t\te[\\index] = 0;
        \t\te[\\list].do { |c, j| if(c.time < from) { e[\\fireNow].(c); e[\\index] = j + 1 } };
        \t\tif(~mode == \\live and: { i < e[\\list].size }) { e[\\index] = i + 1; e[\\fireNow].(e[\\list][i]) };
        \t\te[\\play].(from);
        \t};
        };
        ~triggerCue = { |cue|
        \tvar list = e[\\list] ?? { e[\\list] = e[\\cues].value }, i;
        \te[\\index] = e[\\index] ? 0;
        \ti = if(cue.isNil) { e[\\index] } { list.detectIndex { |c| c.name == cue.asString or: { c.handler == cue } } };
        \tcase
        \t{ i.isNil } { "no cue %".format(cue).postln }
        \t// not playing, or in mockup mode: (re)start there
        \t{ e[\\clock].isNil or: { ~mode == \\mockup } } { e[\\start].(if(e[\\clock].isNil and: { cue.isNil }) { 0 } { i }) }
        \t{ i >= list.size } { "no cue left (~stop.() ends the piece)".postln }
        \t{
        \t\t// live: the cues not run since the last one, at once, then this one
        \t\tif(i > e[\\index]) { (e[\\index]..(i - 1)).do { |j| e[\\fireNow].(list[j]) } };
        \t\te[\\index] = i + 1;
        \t\te[\\fireNow].(list[i]);
        \t}
        };
        ~stop = {
        \te[\\clock] !? { |c| TempoClock.default = e[\\mainClock]; c.clear; SystemClock.sched(0, { c.stop; nil }) };
        \te[\\clock] = nil;
        \te[\\src] !? { e[\\src].free };
        \te[\\src] = nil;
        };
        )

        """
    }

    public static func header(_ cue: CueSheet.Cue) -> String {
        var where_ = "bar \(cue.position.measure)"
        if let b = cue.position.beat { where_ += " beat " + format(b) }
        return headerPrefix + cue.id + " · " + where_ + " · " + seconds(cue.seconds) + " s"
    }

    static func patchStub(_ cue: CueSheet.Cue) -> String {
        """
        \(header(cue))
        ~cue[\\\(cue.handler)] = { |cue|

        };
        \(endPrefix)\(cue.id)

        """
    }

    static func stub(_ cue: CueSheet.Cue) -> String {
        """
        \(header(cue))
        p.on(\\\(cue.handler), { |cue|
        \t// cue \(cue.name) at moment \(cue.position.moment)
        });
        \(endPrefix)\(cue.id)

        """
    }

    struct Block {
        var id: String
        var orphan: Bool
        /// Line indices of the header and the end marker.
        var header: Int
        var end: Int
    }

    static func blocks(_ lines: [String]) -> [Block] {
        var out: [Block] = []
        var open: (id: String, orphan: Bool, header: Int)?
        for (i, line) in lines.enumerated() {
            if let o = open {
                if line == endPrefix + o.id {
                    out.append(Block(id: o.id, orphan: o.orphan, header: o.header, end: i))
                    open = nil
                }
                continue
            }
            if line.hasPrefix(headerPrefix) {
                open = (id(after: headerPrefix, in: line), false, i)
            } else if line.hasPrefix(orphanPrefix) {
                open = (id(after: orphanPrefix, in: line), true, i)
            }
        }
        return out
    }

    /// Handlers the composer wrote outside the markers (`~cue[\cue7] = …`,
    /// `p.on(\cue7, …)`): a stub after one would replace it.
    static func handwritten(_ lines: [String]) -> Set<String> {
        let marked = Set(blocks(lines).flatMap { $0.header...$0.end })
        var names = Set<String>()
        for (i, line) in lines.enumerated() where !marked.contains(i) {
            var rest = line.range(of: "//").map { line[..<$0.lowerBound] } ?? Substring(line)
            while let r = rest.range(of: "\\") {
                let opener = rest[..<r.lowerBound]
                rest = rest[r.upperBound...]
                let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                let after = rest.dropFirst(name.count).drop { $0 == " " }
                let assigned = after.hasPrefix("]") && after.dropFirst().drop { $0 == " " }.prefix(2).first == "="
                    && !after.dropFirst().drop { $0 == " " }.hasPrefix("==")
                if !name.isEmpty, (opener.hasSuffix("~cue[") && assigned) || opener.hasSuffix("p.on(") {
                    names.insert(String(name))
                }
            }
        }
        return names
    }

    private static func id(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count).prefix { $0 != " " })
    }

    public struct Report: Sendable, Hashable {
        public var added: [String] = []
        public var orphaned: [String] = []
        public var restored: [String] = []
        public var moved: [String] = []
    }

    /// Brings `existing` up to date with `sheet`. Stubs follow the file's
    /// style: a patch's `~cue[…] = { … };`, else the quark's `p.on(…)`; a
    /// quark-style file that never creates `p` gets `quark`'s
    /// `p = Pondside(dir, name);` line, so its handlers have a `p` to run on.
    public static func sync(_ existing: String, with sheet: CueSheet,
                            quark: (directory: String, name: String)? = nil) -> (text: String, report: Report) {
        let isPatch = existing.contains(patchMarker)
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if !isPatch, let quark, !existing.contains("Pondside(") {
            // After the file's leading comments.
            let at = lines.firstIndex { !$0.hasPrefix("//") } ?? lines.count
            lines.insert(contentsOf: ["p = Pondside(\"\(quark.directory)\", \"\(quark.name)\");", ""], at: at)
        }
        var report = Report()
        let wanted = Dictionary(sheet.cues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Update, orphan and restore in place, back to front so indices hold.
        for b in blocks(lines).reversed() {
            if let cue = wanted[b.id] {
                let newHeader = header(cue)
                if b.orphan {
                    for i in (b.header + 1)..<b.end where lines[i].hasPrefix(commented) {
                        lines[i] = String(lines[i].dropFirst(commented.count))
                    }
                    report.restored.append(b.id)
                } else if lines[b.header] != newHeader {
                    report.moved.append(b.id)
                }
                lines[b.header] = newHeader
            } else if !b.orphan {
                lines[b.header] = orphanPrefix + b.id + " · its cue is no longer in the score"
                for i in (b.header + 1)..<b.end { lines[i] = commented + lines[i] }
                report.orphaned.append(b.id)
            }
        }

        // Stubs for new cues, each after the block of the cue before it.
        var present = Set(blocks(lines).map(\.id))
        let byHand = handwritten(lines)
        for (i, cue) in sheet.cues.enumerated() where !present.contains(cue.id) && !byHand.contains(cue.handler) {
            let current = blocks(lines)
            let previous = sheet.cues[..<i].reversed().first { c in current.contains { $0.id == c.id } }
            let at: Int
            if let previous, let b = current.first(where: { $0.id == previous.id }) {
                at = b.end + 1
            } else if let first = current.first {
                at = first.header
            } else if let anchor = lines.firstIndex(of: cuesAnchor) {
                at = anchor + 1
            } else {
                // Before a trailing `p.play` line if there is one, else at the end.
                at = lines.lastIndex { $0.contains("p.play") } ?? lines.count
            }
            var stubLines = (isPatch ? patchStub(cue) : stub(cue)).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if stubLines.last == "" { stubLines.removeLast() }
            if at > 0, at <= lines.count, lines[at - 1].hasPrefix(endPrefix) { stubLines.insert("", at: 0) }
            if at < lines.count, !lines[at].isEmpty { stubLines.append("") }
            lines.insert(contentsOf: stubLines, at: at)
            present.insert(cue.id)
            report.added.append(cue.id)
        }
        report.orphaned.reverse()
        report.restored.reverse()
        report.moved.reverse()
        return (lines.joined(separator: "\n"), report)
    }

    private static func seconds(_ s: Double) -> String {
        let ms = Int((s * 1000).rounded())
        let frac = ms % 1000
        return "\(ms / 1000)." + String(repeating: "0", count: 3 - String(frac).count) + String(frac)
    }

    private static func format(_ b: Double) -> String {
        b == b.rounded() ? String(Int(b)) : String((b * 1000).rounded() / 1000)
    }
}

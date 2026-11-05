import Foundation
import PondsideCore
import PondsideTiming

/// The score with its electronics, rendered offline: the patch Pondside
/// started (`HandlerSync.patchStarter`) run in mockup mode against the
/// mockup, in non-real time, into `<name>.mix.wav` beside the score.
///
/// The patch's own `( … )` blocks are run inside a script that is never
/// saved, on a clock far faster than real time: every server message they
/// and their cues send (from routines, patterns, after `s.sync`) is kept at
/// its score time, and scsynth renders the result. Loose lines
/// (`~start.(0);`) are not run.
public enum PatchRender {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// The patch for a score (`patch/<name>.scd`, or `[supercollider] handlers`
    /// in pondside.toml), if it is a Pondside patch.
    public static func patch(for score: URL, configured: URL? = nil) -> URL? {
        let url = PatchMigration.patchURL(score: score, configured: configured)
        return (try? String(contentsOf: url, encoding: .utf8))?.contains(HandlerSync.patchMarker) == true ? url : nil
    }

    /// The mix beside the score.
    public static func output(for score: URL) -> URL {
        HandlerSync.Layout.mix(score: score)
    }

    /// The bodies of the patch's top-level blocks the render runs, in order.
    public static func blocks(in text: String) -> [String] {
        let u = Array(text.utf16)
        return SCRegion.topLevelBlocks(in: text).map { r in
            String(decoding: u[(r.lowerBound + 1)..<(r.upperBound - 1)], as: UTF16.self)
        }.filter { body in
            body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(HandlerSync.liveOnlyMarker) } ?? true
        }
    }

    /// The render's clock: beats are seconds, and the scheduled tasks run in
    /// time order (same-time ones in the order scheduled) as fast as they
    /// can, so `wait`, patterns and `thisThread.seconds` all follow score
    /// time. A class, so sclang loads it from the render's own include path.
    static let clockClass = """
    // Pondside's offline render clock (generated for one render, never saved).
    PondsideRenderClock : Clock {
    \tvar <beats = 0.0, times, items, <>permanent = true;
    \t*new { ^super.new.prInit }
    \tprInit { times = []; items = [] }
    \tseconds { ^beats }
    \ttempo { ^1.0 }
    \ttempo_ { }
    \tbeatDur { ^1.0 }
    \tbeats2secs { |b| ^b }
    \tsecs2beats { |s| ^s }
    \tbeatsPerBar { ^4 }
    \tbaseBarBeat { ^0 }
    \tbar { ^(beats / 4).floor }
    \tbeatInBar { ^beats % 4 }
    \telapsedBeats { ^beats }
    \tisRunning { ^true }
    \tsched { |delta, item| if(delta.notNil) { this.schedAbs(beats + delta, item) } }
    \tschedAbs { |time, item|
    \t\tvar i = times.indexOfGreaterThan(time) ? times.size;
    \t\ttimes = times.insert(i, time);
    \t\titems = items.insert(i, item);
    \t}
    \tplay { |task, quant = 1| this.schedAbs(quant.asQuant.nextTimeOnGrid(this), task) }
    \tnextTimeOnGrid { |quant = 1, phase = 0|
    \t\tif(quant == 0) { ^beats + phase };
    \t\tif(quant < 0) { quant = 4 * quant.neg };
    \t\t^roundUp(beats - phase, quant) + phase
    \t}
    \ttimeToNextBeat { |quant = 1.0| ^quant.nextTimeOnGrid(this) - beats }
    \tclear { times = []; items = [] }
    \tstop { this.clear }
    \t// runs every task due up to `end`, in time order
    \trun { |end, onError|
    \t\tvar t, item, delta;
    \t\tthisThread.clock = this;
    \t\twhile { times.notEmpty and: { times[0] <= end } } {
    \t\t\tt = times.removeAt(0);
    \t\t\titem = items.removeAt(0);
    \t\t\tbeats = t;
    \t\t\tthisThread.beats = t;
    \t\t\tdelta = try { item.awake(t, t, this) } { |e| onError.value(e); nil };
    \t\t\tif(delta.isNumber) { this.schedAbs(t + delta, item) };
    \t\t};
    \t\tbeats = end;
    \t}
    }

    """

    /// sclang's config for a render: the user's own (its include paths:
    /// quarks, extensions), plus the folder with the render's clock.
    static func renderConfig(classes: URL) -> String {
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperCollider/sclang_conf.yaml")
        let line = "    - \(classes.path)"
        guard var text = try? String(contentsOf: user, encoding: .utf8), let r = text.range(of: "includePaths:") else {
            return "includePaths:\n\(line)\nexcludePaths:\n    []\npostInlineWarnings: false\n"
        }
        let rest = text[r.upperBound...]
        if rest.hasPrefix(" []") || rest.hasPrefix(" [ ]") {
            text.replaceSubrange(r.upperBound..<text.index(r.upperBound, offsetBy: rest.hasPrefix(" []") ? 3 : 4), with: "\n" + line)
        } else {
            text.insert(contentsOf: "\n" + line, at: r.upperBound)
        }
        return text
    }

    public static let doneMarker = "PONDSIDE-NRT done"
    /// Printed once the script itself compiled: errors after it are the patch's
    /// (reported, not fatal); errors before it mean the render can't run.
    public static let setupMarker = "PONDSIDE-NRT setup"
    /// Printed when the score's clock starts: errors after it are in cue
    /// code (heard live the same way) and don't stop the render.
    public static let startedMarker = "PONDSIDE-NRT started"

    /// The sclang script: the blocks, played on a clock that runs far
    /// faster than real time while the server is replaced by a recorder
    /// that keeps every message at its score time (and answers `/sync`,
    /// `/done` and `/b_query` as scsynth would); then scsynth renders them.
    public static func script(patch: String, path: URL? = nil, wav: URL, out: URL, osc: URL, tail: Double = 5,
                              blockFiles: [URL]? = nil) -> String {
        func q0(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        // Each block in a file of its own (a long block is more than one string literal
        // can hold), compiled when it runs: one that doesn't compile (a class only SC's
        // IDE has) is reported and skipped, and the rest still render.
        let bodies = (blockFiles?.map { "File.readAllString(\(q0($0.path)))" } ?? blocks(in: patch).map(q0)).joined(separator: ",\n")
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return """
        // Pondside's offline render of a patch in mockup mode (generated, never saved).
        (
        var blocks = [
        \(bodies)
        ];
        var wav = \(q(wav.path)), info = SoundFile.openRead(wav), sr, end, opts;
        var syncing = 0, quiet, running = false, mainClock = TempoClock.default, real = s.addr, rec = List[], last = 0, clock, now, fake, bufs = (), reply, play, stop, finish, finished = false;
        if(info.isNil) { "PONDSIDE-NRT no mockup at %".format(wav).postln; 1.exit };
        sr = info.sampleRate; end = info.duration + \(tail); info.close;

        // the server, as a recorder: each message at the score time it was sent
        now = { if(clock.notNil and: { thisThread.clock === clock }) { last = thisThread.beats } { last } };
        reply = { |msg| thisProcess.recvOSCmessage(0, real, nil, msg) };
        fake = (addr: real.addr, port: real.port, hostname: real.hostname, socket: nil, hasBundle: false, isLocal: true);
        fake[\\record] = { |self, offset, msgs|
        \tvar t = now.() + (offset ? 0);
        \tmsgs.do { |m|
        \t\tvar name;
        \t\tm = m.asArray; name = m[0].asString;
        \t\tif(name.beginsWith("/").not) { name = "/" ++ name };
        \t\tif(["/sync", "/notify", "/status", "/quit", "/dumpOSC"].includesEqual(name).not and: { t <= end }) { rec.add([t, rec.size, m]) };
        \t\tcase
        \t\t{ name == "/sync" } { reply.(['/synced', m[1]]) }
        \t\t{ name == "/b_allocRead" or: { name == "/b_allocReadChannel" } } { bufs[m[1]] = m[2] }
        \t\t{ name == "/b_alloc" } { bufs[m[1]] = [m[2], m[3] ? 1] };
        \t\tif(["/b_alloc", "/b_allocRead", "/b_allocReadChannel", "/b_read", "/b_readChannel", "/b_write", "/b_free", "/b_zero",
        \t\t\t"/b_gen", "/b_close", "/d_recv", "/d_load", "/d_loadDir"].includesEqual(name)) { reply.(['/done', name.asSymbol, m[1]]) };
        \t\t([m] ++ m.select { |x| x.isKindOf(Array) }).do { |x|
        \t\t\tif(x[0].asString.replace("/", "") == "b_query") { x.drop(1).do { |b|
        \t\t\t\tvar i = bufs[b], f = if(i.isString) { SoundFile.openRead(i) };
        \t\t\t\tif(f.notNil) { reply.(['/b_info', b, f.numFrames, f.numChannels, f.sampleRate]); f.close }
        \t\t\t\t{ if(i.isArray) { reply.(['/b_info', b, i[0], i[1], sr]) } }
        \t\t\t} }
        \t\t};
        \t}
        };
        fake[\\sendMsg] = { |self ... m| self.record(nil, [m]) };
        fake[\\sendBundle] = { |self, time ... m| self.record(time, m) };
        fake[\\sendClumpedBundles] = fake[\\sendBundle];
        // A real sync returns once the server has done everything sent before it, so
        // the callbacks of those commands (a buffer loader's onComplete) have run too, and
        // code after s.sync relies on that. During setup, wait until setup goes quiet
        // (nothing sent for 0.2 s, at most 5 s). In the piece, on the render's clock,
        // everything is in order already.
        fake[\\sync] = { |self, condition, bundles, latency|
        \tvar n, tries = 0;
        \tself.record(latency, (bundles ? []) ++ [["/sync", 0]]);
        \tif(running.not and: { thisThread.isKindOf(Routine) }) {
        \t\tsyncing = syncing + 1;
        \t\twhile { n = rec.size; 0.2.wait; tries = tries + 1; rec.size != n and: { tries < 25 } } {};
        \t\tsyncing = syncing - 1;
        \t\tif(tries > 5) { "PONDSIDE-NRT setup: an s.sync waited % s for setup to go quiet (% messages so far; last: %)"
        \t\t\t.format(tries * 0.2, rec.size, rec.last !? { |r| r[2].keep(2) }).postln };
        \t};
        };
        // setup is done when no sync is waiting and nothing was sent for 0.2 s (at most 20 s)
        quiet = { var n = -1, tries = 0;
        \twhile { (syncing > 0 or: { rec.size != n }) and: { tries < 100 } } { n = rec.size; 0.2.wait; tries = tries + 1 };
        };
        fake[\\sendRaw] = { "PONDSIDE-NRT raw OSC isn't rendered".postln };
        fake[\\sendStatusMsg] = {};
        fake[\\recover] = { |self| self };
        s.slotPut(\\addr, fake);
        // already "booted": s.boot is a no-op, waitForBoot runs its function; and,
        // as for a remote server, s.reboot and s.quit do nothing
        s.statusWatcher.notified = true;
        s.statusWatcher.serverRunning = true;
        s.remoteControlled = true;
        // what a running server would report (s.sampleRate is nil until /status.reply)
        s.statusWatcher.slotPut(\\sampleRate, sr).slotPut(\\actualSampleRate, sr).slotPut(\\avgCPU, 0).slotPut(\\peakCPU, 0);

        finish = {
        \tvar defs, bundles = List[], add, size, defDir = \(q(osc.deletingLastPathComponent().appendingPathComponent("defs").path)), n = 0;
        \tif(finished.not) {
        \t\tfinished = true;
        \t\tclock.clear;                                   // (a clock stopped from its own thread hangs sclang)
        \t\tSystemClock.sched(0, { clock.stop; nil });
        \t\tTempoClock.default = mainClock;               // Score reads its tempo
        \t\ts.slotPut(\\addr, real);
        \t\t// SynthDefs go to files (a def's bytes in a bundle can pass sclang's packet
        \t\t// limit): every one sclang knows, as a boot sends them (the class library's
        \t\t// own too: \\default, and the system_link_* defs Pbus and Pfx route through),
        \t\t// and below, any the patch sent itself
        \t\tFile.mkdir(defDir);
        \t\tdefs = SynthDescLib.global.synthDescs.values.collect(_.def).reject(_.isNil);
        \t\tdefs.do { |d| d.writeDefFile(defDir) };
        \t\t// bundles of one time, each under ~8 KB, in the order they were sent
        \t\tsize = { |x| case { x.isKindOf(RawArray) } { x.size + 8 } { x.isKindOf(SequenceableCollection) } { x.sum { |y| size.(y) } + 16 } { 8 } };
        \t\tadd = { |t, m|
        \t\t\tif(bundles.notEmpty and: { bundles.last[0] == t } and: { size.(bundles.last) + size.(m) < 8000 }) {
        \t\t\t\tbundles.last.add(m)
        \t\t\t} { bundles.add(List[t, m]) }
        \t\t};
        \t\tadd.(0.0, [\\g_new, 1, 0, 0]);
        \t\tadd.(0.0, [\\d_loadDir, defDir]);
        \t\trec.copy.sort { |a, b| (a[0] < b[0]) or: { a[0] == b[0] and: { a[1] < b[1] } } }.do { |r|
        \t\t\tvar m = r[2], path;
        \t\t\tif(m[0].asString.replace("/", "") == "d_recv") {
        \t\t\t\tpath = defDir +/+ "sent" ++ (n = n + 1) ++ ".scsyndef";
        \t\t\t\tFile.use(path, "wb", { |f| f.write(m[1]) });
        \t\t\t\tm = [\\d_load, path] ++ m.drop(2);
        \t\t\t};
        \t\t\tadd.(max(r[0], 0.0), m)
        \t\t};
        \t\topts = s.options.copy;
        \t\topts.sampleRate = sr;
        \t\t// no duration: Score would re-sort a section; the score ends at `end` itself
        \t\ttry {
        \t\t\tScore(bundles.collect(_.asArray).asArray ++ [[end, [\\c_set, 0, 0]]]).recordNRT(
        \t\t\t\t\(q(osc.path)), \(q(out.path)), nil, sr, "WAV", "int24", opts, "", nil,
        \t\t\t\t{ "\(doneMarker)".postln; 0.exit });
        \t\t} { |e|
        \t\t\t"PONDSIDE-NRT the score couldn't be written: %".format(e.errorString.replace("ERROR:", "")).postln;
        \t\t\t1.exit
        \t\t};
        \t};
        \tnil
        };

        // The patch's blocks one at a time, as a person runs them: each block's deferred
        // work (a waitForBoot body, a fork) runs before the next block (relative paths
        // resolve beside the patch; setup sees mockup mode). Then the piece, in mockup mode.
        ~pondsideMode = \\mockup;
        ~renderClock = PondsideRenderClock.new;   // the engine's ~play takes it (~clock = ~renderClock ?? …)
        "\(setupMarker)".postln;
        Routine {
        \tblocks.do { |b, i| var f;
        \t\tthisProcess.nowExecutingPath = \(path.map { q($0.path) } ?? "nil");
        \t\tf = thisProcess.interpreter.compile(b);
        \t\tif(f.isNil) { "PONDSIDE-NRT block % doesn't compile (see the error above); skipped".format(i + 1).postln } {
        \t\t\tf.try { |e| "PONDSIDE-NRT block % failed: %".format(i + 1, e.errorString.replace("ERROR:", "")).postln };
        \t\t};
        \t\t~mode = \\mockup;
        \t\t0.25.wait;
        \t};
        \tquiet.value;
        \t// the engine's: ~pondside[\\play] starts the source and the clock; ~stop ends it all
        \tplay = ~pondside !? { ~pondside[\\play] };
        \tstop = ~stop;
        \tif(play.isNil) { "PONDSIDE-NRT no engine: the patch must load dependencies/pondside.scd".postln; 1.exit };
        \t~stop = { stop.value; if(clock.notNil) { SystemClock.sched(0, { finish.value; nil }) } };  // a cue that stops it all
        \t~pondside[\\play] = { |from|
        \t\tplay.value(from);
        \t\tclock = ~pondside[\\clock];
        \t\t"\(startedMarker)".postln;
        \t\t// the whole piece, in score order, now
        \t\tRoutine {
        \t\t\trunning = true;
        \t\t\tclock.run(end, { |e| ("ERROR in a cue: " ++ e.errorString.replace("ERROR:", "")).postln });
        \t\t\trunning = false;
        \t\t\tfinish.value;
        \t\t}.next;
        \t};
        \t~triggerCue.();   // cue 1 starts the piece, from the start
        }.play(AppClock);
        )

        """
    }

    /// Renders `patch` against `wav` into `out` (written whole, never
    /// half). Fails with sclang's output on an error or after `timeout`.
    /// Returns the errors its cues printed (they don't stop the render).
    @discardableResult
    public static func render(sclang: String, patch: URL, wav: URL, out: URL, timeout: Double = 300) async throws -> [String] {
        let text = try String(contentsOf: patch, encoding: .utf8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let classes = dir.appendingPathComponent("classes")
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        try Data(clockClass.utf8).write(to: classes.appendingPathComponent("PondsideRenderClock.sc"))
        let config = dir.appendingPathComponent("sclang_conf.yaml")
        // A headless sclang leaves the user's extensions out (they may need Qt).
        try Data((SuperColliderToolchain.isHeadless(sclang) ? SuperColliderToolchain.headlessConfig(sclang, extra: [classes.path])
                  : renderConfig(classes: classes)).utf8).write(to: config)
        let script = dir.appendingPathComponent("render.scd")
        let partial = dir.appendingPathComponent("mix.wav")
        let blockDir = dir.appendingPathComponent("blocks")
        try FileManager.default.createDirectory(at: blockDir, withIntermediateDirectories: true)
        let blockFiles = try blocks(in: text).enumerated().map { i, body -> URL in
            let f = blockDir.appendingPathComponent("\(i + 1).scd")
            try Data(body.utf8).write(to: f)
            return f
        }
        try Data(self.script(patch: text, path: patch, wav: wav, out: partial, osc: dir.appendingPathComponent("score.osc"), blockFiles: blockFiles).utf8).write(to: script)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sclang)
        process.arguments = ["-l", config.path, script.path]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let log = OutputLog()
        // sclang stays up after an error: stop it when one is printed.
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if log.append(data), process.isRunning { process.terminate() }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline { process.terminate(); break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let output = log.text
        // For debugging a mix: PONDSIDE_MIX_KEEP=<dir> keeps the script, its OSC score and its log.
        if let keep = ProcessInfo.processInfo.environment["PONDSIDE_MIX_KEEP"], !keep.isEmpty {
            let k = URL(fileURLWithPath: keep)
            try? FileManager.default.createDirectory(at: k, withIntermediateDirectories: true)
            for f in ["render.scd", "score.osc"] {
                let dst = k.appendingPathComponent(f)
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: dir.appendingPathComponent(f), to: dst)
            }
            try? Data(output.utf8).write(to: k.appendingPathComponent("sclang.log"))
        }
        guard output.contains(doneMarker), FileManager.default.fileExists(atPath: partial.path) else {
            throw Failure(description: "the patch didn't render:\n" + output.split(separator: "\n").suffix(30).joined(separator: "\n"))
        }
        _ = try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: partial, to: out)
        return problems(in: output)
    }

    /// The errors sclang printed once the score's clock ran (in cue code),
    /// and the blocks that failed in setup, each with the line after it.
    public static func problems(in output: String) -> [String] {
        let lines = output.components(separatedBy: "\n")
        var out: [String] = []
        var started = false
        for (i, l) in lines.enumerated() {
            if l.contains(startedMarker) { started = true }
            if l.hasPrefix("PONDSIDE-NRT block") || l.hasPrefix("PONDSIDE-NRT setup:") || (started && l.hasPrefix("ERROR:")) {
                let next = i + 1 < lines.count && !lines[i + 1].hasPrefix("ERROR") ? " " + lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
                let p = l + next
                if !out.contains(p) { out.append(p) }
            }
        }
        return Array(out.prefix(20))
    }

    /// sclang's output so far; `append` says whether it printed an error.
    final class OutputLog: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ d: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            data.append(d)
            let s = String(decoding: data, as: UTF8.self)
            // sclang's own errors start a line; scsynth's plugin complaints
            // ("*** ERROR: dlopen …") don't stop a render, nor do errors in
            // cue code once the score's clock runs.
            let setup = s.components(separatedBy: PatchRender.setupMarker)[0]
            return setup.split(separator: "\n").contains { $0.hasPrefix("ERROR:") } || s.contains("PONDSIDE-NRT no mockup")
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

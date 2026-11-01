import Foundation
import PondsideCore

/// What makes a SuperCollider file a Pondside patch, and making one that
/// isn't into one (docs/SUPERCOLLIDER.md).
///
/// `audit` lists what keeps a file from working with Pondside: what
/// `migrate` changes by itself (`automatic`), and what needs a person or an
/// agent (the sc-patch-migration skill). `migrate` keeps every line of the
/// composer's code; it renames, converts and moves, and marks each line
/// left for an agent with a `// pondside:` comment.
public enum PatchMigration {
    public struct Finding: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            // done by `migrate`
            case notAPatch, location, quark, engine, collision, soundIn
            // left for a person or an agent
            case loose, timeline, clock, gui, trigger, input, recording, engineName, pipeline, ideOnly
        }
        public var kind: Kind
        /// A file the patch loads (relative to the patch's folder), or nil
        /// for the patch itself.
        public var file: String?
        /// 1-based, in the file the finding is about.
        public var line: Int?
        public var message: String
        public var automatic: Bool { Self.automaticKinds.contains(kind) }

        static let automaticKinds: Set<Kind> = [.notAPatch, .location, .quark, .engine, .collision, .soundIn]

        public init(_ kind: Kind, line: Int?, _ message: String, file: String? = nil) {
            self.kind = kind
            self.line = line
            self.message = message
            self.file = file
        }
    }

    /// The comment `migrate` puts on lines left for an agent; a line that
    /// has one is not reported again.
    public static let note = "// pondside:"

    /// The lines still marked with `note` (1-based, with their text), not
    /// counting the header comment that explains the marks.
    public static func marks(in text: String) -> [(line: Int, text: String)] {
        text.components(separatedBy: "\n").enumerated().compactMap { i, l in
            l.contains(note) && !l.hasPrefix("// Migrated from") ? (i + 1, l.trimmingCharacters(in: .whitespaces)) : nil
        }
    }

    /// What the engine block defines: a patch's own code that used these
    /// names would overwrite it, so `migrate` renames them (`~buf` → `~myBuf`).
    public static let engineNames: Set<String> = ["mode", "cue", "live", "triggerCue", "stop", "pondside", "renderClock"]

    // MARK: Finding the patch

    /// Where `score`'s patch lives (`patch/<name>.scd`), unless pondside.toml says otherwise.
    public static func patchURL(score: URL, configured: URL? = nil) -> URL {
        configured ?? score.deletingLastPathComponent().appendingPathComponent("patch")
            .appendingPathComponent(score.deletingPathExtension().lastPathComponent + ".scd")
    }

    /// The engine beside a patch: `dependencies/pondside.scd`.
    public static func engineURL(patch: URL) -> URL {
        patch.deletingLastPathComponent().appendingPathComponent(HandlerSync.Layout.engineFile)
    }

    /// Writes the engine for `patch` if it is missing or not the current one.
    /// Returns whether it wrote.
    @discardableResult
    public static func ensureEngine(patch: URL, name: String) throws -> Bool {
        let url = engineURL(patch: patch), text = HandlerSync.engine(name: name)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }

    /// The file Pondside should offer to migrate for `score`: its patch
    /// (`patch/<name>.scd`, or pondside.toml's) if that has unreported
    /// findings, else, when there is no patch yet, the likeliest
    /// SuperCollider file in the score's folder or its `patch/` folder.
    /// `target` is where the migrated patch goes.
    public static func candidate(score: URL, configured: URL? = nil)
        -> (source: URL, target: URL, findings: [Finding])? {
        let target = patchURL(score: score, configured: configured)
        let name = score.deletingPathExtension().lastPathComponent
        if let text = try? String(contentsOf: target, encoding: .utf8), !isUntouchedStarter(text) {
            var f = audit(text) + auditDependencies(of: target)
            if text.contains(HandlerSync.patchMarker),
               (try? String(contentsOf: engineURL(patch: target), encoding: .utf8)) != HandlerSync.engine(name: name) {
                f.insert(Finding(.engine, line: nil, "the engine (\(HandlerSync.Layout.engineFile)) is missing or out of date: Pondside writes it"), at: 0)
            }
            return f.isEmpty ? nil : (target, target, f)
        }
        let root = score.deletingLastPathComponent()
        let files = [root, root.appendingPathComponent("patch")].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        // A custom patch: not the target (an untouched starter there is "no patch
        // yet"), not a backup, not another Pondside patch.
        let scored = files.filter { $0.pathExtension == "scd" && !$0.lastPathComponent.hasPrefix(".")
            && !$0.lastPathComponent.hasSuffix(".before-pondside.scd")
            && $0.standardizedFileURL != target.standardizedFileURL }
            .compactMap { url -> (URL, Int, String)? in
                guard let text = try? String(contentsOf: url, encoding: .utf8), !text.contains(HandlerSync.patchMarker) else { return nil }
                let hits = ["SynthDef", "Synth(", "Synth.", ".play", "p.on(", "waitForBoot", "Buffer."]
                    .map { text.components(separatedBy: $0).count - 1 }.reduce(0, +)
                return hits > 0 ? (url, hits, text) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastPathComponent < $1.0.lastPathComponent }
        guard let best = scored.first else { return nil }
        var f = audit(best.2) + auditDependencies(of: best.0)
        f.insert(Finding(.location, line: nil,
                         "it moves to patch/\(target.lastPathComponent), with the files it uses; the .ly files stay, and renders go in renders/"), at: 0)
        return (best.0, target, f)
    }

    /// A patch as Pondside started it, with nothing of the composer's in
    /// it yet (the SuperCollider pane writes one when it opens): a custom
    /// patch beside it is still offered.
    public static func isUntouchedStarter(_ text: String) -> Bool {
        guard text.contains(HandlerSync.patchMarker) else { return false }
        // The code outside the engine, with empty handler stubs left out.
        func skeleton(_ t: String) -> String {
            let stubs = try! NSRegularExpression(pattern: #"~cue\[\\\w+\] = \{ \|cue\|\s*\};"#)
            let bare = stubs.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
            let src = Source(bare)
            return src.code.filter { !src.isExcluded($0.range.lowerBound) }.map { src.text($0.range) }.joined(separator: " ")
                .replacingOccurrences(of: "~mode = \\live", with: "~mode = \\mockup")
        }
        return skeleton(text) == skeleton(HandlerSync.patchStarter(CueSheet(log: TimingLog(rows: []), score: "score.ly"), name: ""))
    }

    // MARK: Audit

    /// Everything that keeps `text` from working fully with Pondside.
    public static func audit(_ text: String) -> [Finding] {
        let src = Source(text)
        var out: [Finding] = []
        if !src.isPatch {
            out.append(Finding(.notAPatch, line: nil,
                               "not a Pondside patch: Pondside adds a block that loads its engine at the top, and the cue handlers and run lines at the end; your code stays as it is"))
        }
        if let at = src.quarkCalls.first {
            out.append(Finding(.quark, line: src.line(at),
                               "Pondside-quark handlers (p.on) become ~cue[…] handlers in the cue section; p = Pondside(…) and p.play lines are commented out"))
        }
        if !src.isPatch {
            var seen = Set<String>()
            for t in src.collisions where seen.insert(src.text(t.range)).inserted {
                let name = String(src.text(t.range).dropFirst())
                out.append(Finding(.collision, line: src.line(t.range.lowerBound),
                                   "~\(name) is the engine's: yours is renamed ~\(renamed(name, in: src))"))
            }
        }
        for r in src.soundInZero {
            out.append(Finding(.soundIn, line: src.line(r.lowerBound),
                               "SoundIn.ar(0) becomes In.ar(~live): the mockup in mockup mode, input 0 live"))
        }
        return out + manual(src)
    }

    /// The findings only a person or an agent can resolve, skipping lines
    /// already marked with `note`.
    static func manual(_ src: Source) -> [Finding] {
        var out: [Finding] = []
        var lastLoose = -2
        func add(_ kind: Finding.Kind, _ offset: Int, _ message: String) {
            let line = src.line(offset)
            if kind == .loose {
                // One note for each run of loose lines.
                defer { lastLoose = line }
                if line <= lastLoose + 1 { return }
            }
            guard !src.lineText(line).contains(note), !out.contains(where: { $0.line == line && $0.kind == kind }) else { return }
            out.append(Finding(kind, line: line, message))
        }
        let code = src.code
        var depth = 0
        for (k, t) in code.enumerated() {
            let word = src.text(t.range)
            let prev = k > 0 ? src.text(code[k - 1].range) : ""
            let prev2 = k > 1 ? src.text(code[k - 2].range) : ""
            let next = k + 1 < code.count ? src.text(code[k + 1].range) : ""
            let next2 = k + 2 < code.count ? src.text(code[k + 2].range) : ""
            defer {
                if t.kind == .openBrace { depth += 1 } else if t.kind == .closeBrace { depth = max(0, depth - 1) }
            }
            let at = t.range.lowerBound
            guard !src.isExcluded(at) else { continue }
            let inBlock = src.blocks.contains { $0.contains(at) }
            // Loose code that defines what the piece needs (test lines that
            // only call or set things are fine where they are).
            if !inBlock, !src.isQuarkOrPlayLine(src.line(at)), src.definesSomething(line: src.line(at)) {
                add(.loose, at, "defines something the piece needs, but only when run by hand: the mix never runs it. Put it in a ( … ) block, or in a cue if it happens in the piece")
            }
            switch t.kind {
            case .className where word == "SystemClock" || (word == "AppClock" && next == "." && next2.hasPrefix("sched")):
                add(.clock, at, "timed by \(word): not in the mix and not stopped by ~stop; wait in a cue instead (cues run on the score's clock)")
            case .className where ["Window", "FreqScope", "Stethoscope", "ServerMeter", "ScopeView", "NdefGui", "EnvirGui"].contains(word):
                add(.gui, at, "opens a window on every mix render: move it to a block whose first line is \(HandlerSync.liveOnlyMarker)")
            case .identifier where prev == "." && ["front", "plot", "scope", "meter", "makeWindow", "gui"].contains(word):
                add(.gui, at, "opens a window on every mix render: move it to a block whose first line is \(HandlerSync.liveOnlyMarker)")
            case .className where ["MIDIdef", "MIDIFunc", "OSCdef", "OSCFunc", "MIDIIn", "HIDdef", "HIDFunc"].contains(word):
                add(.trigger, at, "a trigger: if it fires cues, call ~triggerCue.() (the next cue) or ~triggerCue.(N) from it, and set it up in a \(HandlerSync.liveOnlyMarker) block")
            case .identifier where ["keyDownAction", "keyDownFunc"].contains(word):
                add(.trigger, at, "a trigger: if it fires cues, call ~triggerCue.() (the next cue) or ~triggerCue.(N) from it, and set it up in a \(HandlerSync.liveOnlyMarker) block")
            case .className where word == "SoundIn" && !src.soundInZero.contains(where: { $0.lowerBound == at }):
                add(.input, at, "reads a hardware input: use In.ar(~live), Pondside's live signal (the mockup, or input 0 live), or change \\pondsideMic")
            case .className where word == "Document":
                add(.ideOnly, at, "Document exists only in SC's IDE, so this block can't run in Pondside's mix: use \"x\".resolveRelative for paths beside the patch, or move it to a block whose first line is \(HandlerSync.liveOnlyMarker)")
            case .className where ["Recorder", "DiskOut"].contains(word):
                add(.recording, at, "records to disk on every mix render: Pondside's mix is the recording; move it to a \(HandlerSync.liveOnlyMarker) block")
            case .identifier where prev == "." && word == "record" && prev2 == "s":
                add(.recording, at, "records to disk on every mix render: Pondside's mix is the recording; move it to a \(HandlerSync.liveOnlyMarker) block")
            case .identifier where inBlock && depth == 0 && ((prev == "." && ["play", "fork"].contains(word)) || (word == "fork" && next == "{")):
                add(.timeline, at, "starts when its block runs, so at 0:00 in the mix: start it from a cue, unless it should sound from the start")
            case .environment where (src.isPatch || src.isDependency) && word != "~mode"
                && PatchMigration.engineNames.contains(String(word.dropFirst()))
                && next == "=" && !(next2.hasPrefix("=")):
                add(.engineName, at, "assigns \(word), which Pondside's engine uses: rename it here and wherever the patch uses it")
            case .string where ["export_piece", "lily_timing", "piece.cues", "timing.ily", ".timing\""].contains(where: word.contains):
                add(.pipeline, at, "a second timing pipeline: Pondside writes the cue times (score.cues) and the engine fires the handlers at them; remove this and what depends on it")
            default: break
            }
        }
        return out.sorted { ($0.line ?? 0) < ($1.line ?? 0) }
    }

    // MARK: Loaded files

    /// The SuperCollider files `patch` loads (`"x.scd".resolveRelative.load`,
    /// `"x.scd".loadRelative`, `load("…")`), and the files they load, outside
    /// live-only blocks: their code runs in the mix too.
    public static func dependencies(of patch: URL) -> [URL] {
        var seen: [URL] = [], queue = [patch.standardizedFileURL]
        while let file = queue.first {
            queue.removeFirst()
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let src = Source(text, dependency: file != patch.standardizedFileURL)
            for path in src.loads {
                let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
                           : file.deletingLastPathComponent().appendingPathComponent(path)).standardizedFileURL
                // Pondside's own engine is not the composer's to audit.
                guard url != patch.standardizedFileURL, url.lastPathComponent != "pondside.scd" || url.deletingLastPathComponent().lastPathComponent != "dependencies",
                      !seen.contains(url), FileManager.default.fileExists(atPath: url.path) else { continue }
                seen.append(url)
                queue.append(url)
            }
        }
        return seen
    }

    /// The path of `file` as findings name it: relative to the patch's folder.
    static func relative(_ file: URL, to patch: URL) -> String {
        let base = patch.deletingLastPathComponent().standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    /// What needs a person or an agent in the files `patch` loads.
    public static func auditDependencies(of patch: URL) -> [Finding] {
        dependencies(of: patch).flatMap { url -> [Finding] in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return manual(Source(text, dependency: true)).map {
                Finding($0.kind, line: $0.line, $0.message, file: relative(url, to: patch))
            }
        }
    }

    /// Every line still marked, in the patch and the files it loads.
    public static func allMarks(patch: URL) -> [(file: String, line: Int, text: String)] {
        ([patch] + dependencies(of: patch)).flatMap { url -> [(file: String, line: Int, text: String)] in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return marks(in: text).map { (url == patch ? url.lastPathComponent : relative(url, to: patch), $0.line, $0.text) }
        }
    }

    // MARK: Migrate

    public struct Result: Sendable {
        public var text: String
        /// What `migrate` did.
        public var applied: [Finding]
        /// What is left, with lines in `text` (each marked with `note`).
        public var manual: [Finding]
    }

    /// `text` as a Pondside patch for `score` (the root file's name, whose
    /// renders are `renders/<name>.*`). `source` names the file it came from.
    /// The composer's code stays where it is: a block loading the engine goes
    /// on top, the cue handlers and run lines at the end. With a cue sheet,
    /// every cue gets its handler stub.
    public static func migrate(_ text: String, source: String, score: String, name: String,
                               sheet: CueSheet? = nil) -> Result {
        let applied = audit(text).filter(\.automatic)
        var t = text
        let isPatch = Source(t).isPatch
        if !isPatch { t = rename(t) }
        t = convertQuark(t)
        t = replace(t, ranges: Source(t).soundInZero, with: "In.ar(~live)")
        if !isPatch {
            let (rest, handlers) = takeHandlerBlocks(t)
            var user = rest
            if !user.hasSuffix("\n") { user += "\n" }
            t = """
            \(HandlerSync.patchMarker) for \(score) (from \(source)). Run each ( … ) block with ⌘↩, a line with ⇧↩.
            \(HandlerSync.engineIntro(name: name))

            \(HandlerSync.setupBlock)

            \(user)
            // Cues: ~cue[\\cueN] runs at cue N, as a routine (wait, fork and patterns work).
            (
            \(HandlerSync.cuesAnchor)
            \(handlers.joined(separator: "\n")))

            \(HandlerSync.runLines)
            """
        }
        if let sheet { t = HandlerSync.sync(t, with: sheet).text }

        let pending = manual(Source(t))
        if !pending.isEmpty, !t.contains("\n// Lines marked \(note)") {
            var lines = t.components(separatedBy: "\n")
            lines.insert("// Lines marked \(note) need you or an agent (Pondside's refactor runs one; or, in the terminal pane: claude, then /mcp__pondside__sc-patch-migration).", at: 1)
            t = lines.joined(separator: "\n")
        }
        let left = manual(Source(t))
        return Result(text: annotate(t, left), applied: applied, manual: left)
    }

    /// Migrates `source` into `target` (`patch/<name>.scd`) for `score`:
    /// - the files and folders the patch refers to by relative path
    ///   (`"dependencies/x.scd".loadRelative`, `"resources/y.wav".resolveRelative`)
    ///   move with it into `patch/`; paths to what stays (the score's files,
    ///   anything outside the folder) gain a `../`;
    /// - the original is kept as `patch/<its name>.before-pondside.scd` (once)
    ///   and leaves the score's folder;
    /// - the engine is written to `patch/dependencies/pondside.scd`;
    /// - old renders beside the score (`<name>.wav`, `.cues`, `.mix.wav`) move
    ///   into `renders/`;
    /// - the files the patch loads get marks (comments) where they need an agent.
    public static func write(score: URL, source: URL, target: URL, sheet: CueSheet?) throws
        -> (result: Result, backup: URL?, moved: [String]) {
        let fm = FileManager.default
        let root = score.deletingLastPathComponent().standardizedFileURL
        let patchDir = target.deletingLastPathComponent().standardizedFileURL
        let name = score.deletingPathExtension().lastPathComponent
        let original = try String(contentsOf: source, encoding: .utf8)
        let srcDir = source.deletingLastPathComponent().standardizedFileURL
        try fm.createDirectory(at: patchDir, withIntermediateDirectories: true)
        var moved: [String] = []

        // What the patch refers to, and its paths from patch/.
        var text = original
        var tops: [String] = []
        if srcDir != patchDir {
            let src = Source(original)
            var edits: [(Range<Int>, String)] = []
            for (range, path) in src.relativePaths {
                let abs = srcDir.appendingPathComponent(path).standardizedFileURL
                let rel = abs.path.hasPrefix(root.path + "/") ? String(abs.path.dropFirst(root.path.count + 1)) : nil
                if let rel, let top = rel.split(separator: "/").first.map(String.init),
                   !["patch", HandlerSync.Layout.renders].contains(top), !["ly", "ily"].contains(URL(fileURLWithPath: top).pathExtension),
                   fm.fileExists(atPath: root.appendingPathComponent(top).path) {
                    if !tops.contains(top) { tops.append(top) }
                    if srcDir != root { edits.append((range, "\"\(rel)\"")) }
                } else {
                    // stays: reach it from patch/
                    let back = rel.map { "../" + $0 } ?? relativePath(from: patchDir, to: abs)
                    edits.append((range, "\"\(back)\""))
                }
            }
            text = apply(original, edits)
        }

        let result = migrate(text, source: source.lastPathComponent, score: score.lastPathComponent, name: name, sheet: sheet)

        // Move what the patch uses (merging into a folder that is already there).
        func move(_ from: URL, _ to: URL) throws {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: to.path, isDirectory: &isDir) {
                guard isDir.boolValue else { return }
                for child in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                    try move(child, to.appendingPathComponent(child.lastPathComponent))
                }
                if ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? fm.removeItem(at: from) }
            } else {
                try fm.moveItem(at: from, to: to)
            }
        }
        for top in tops {
            try move(root.appendingPathComponent(top), patchDir.appendingPathComponent(top))
            moved.append("\(top) → patch/\(top)")
        }

        // The original: kept as a backup in patch/, gone from the score's folder.
        let backup = patchDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".before-pondside.scd")
        if !fm.fileExists(atPath: backup.path) { try Data(original.utf8).write(to: backup) }
        if source.standardizedFileURL != target.standardizedFileURL, srcDir != patchDir {
            try? fm.removeItem(at: source)
            moved.append("\(source.lastPathComponent) → patch/\(target.lastPathComponent)")
        }
        try Data(result.text.utf8).write(to: target, options: .atomic)
        try ensureEngine(patch: target, name: name)

        // Old renders beside the score go to renders/.
        let renders = root.appendingPathComponent(HandlerSync.Layout.renders)
        for ext in ["wav", "cues", "mix.wav", "timing"] {
            let old = root.appendingPathComponent(name + "." + ext), new = renders.appendingPathComponent(name + "." + ext)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            try fm.createDirectory(at: renders, withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            moved.append("\(old.lastPathComponent) → renders/")
        }

        // The files it loads only get marks (comments), each kept first as it was.
        var all = result
        for url in dependencies(of: target) where url != engineURL(patch: target).standardizedFileURL {
            guard let dep = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let found = manual(Source(dep, dependency: true))
            guard !found.isEmpty else { continue }
            let b = url.deletingPathExtension().appendingPathExtension("before-pondside.scd")
            if !fm.fileExists(atPath: b.path) { try Data(dep.utf8).write(to: b) }
            try Data(annotate(dep, found).utf8).write(to: url, options: .atomic)
            all.manual += found.map { Finding($0.kind, line: $0.line, $0.message, file: relative(url, to: target)) }
        }
        return (all, backup, moved)
    }

    /// A relative path from `dir` to `file`.
    static func relativePath(from dir: URL, to file: URL) -> String {
        let a = dir.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }

    // MARK: Steps

    static func renamed(_ name: String, in src: Source) -> String {
        let base = "my" + name.prefix(1).uppercased() + name.dropFirst()
        var candidate = base
        var n = 2
        while src.environmentNames.contains(candidate) { candidate = base + String(n); n += 1 }
        return candidate
    }

    static func rename(_ text: String) -> String {
        let src = Source(text)
        var edits: [(Range<Int>, String)] = []
        var names: [String: String] = [:]
        for t in src.collisions {
            let name = String(src.text(t.range).dropFirst())
            let new = names[name] ?? renamed(name, in: src)
            names[name] = new
            edits.append((t.range, "~" + new))
        }
        return apply(text, edits)
    }

    /// `p.on(\x, { … })` → `~cue[\x] = { … }`; the quark's own lines
    /// commented out.
    static func convertQuark(_ text: String) -> String {
        let src = Source(text)
        var edits: [(Range<Int>, String)] = []
        for at in src.quarkCalls {
            // p . on ( \x ,
            guard let k = src.code.firstIndex(where: { $0.range.lowerBound == at }), k + 5 < src.code.count,
                  let close = SCRegion.matchingBracket(in: text, at: src.code[k + 3].range.lowerBound),
                  src.code[k + 4].kind == .symbol, src.text(src.code[k + 5].range) == "," else { continue }
            let symbol = src.text(src.code[k + 4].range)
            edits.append((at..<src.code[k + 5].range.upperBound, "~cue[\(symbol)] ="))
            edits.append((close..<(close + 1), ""))
        }
        var t = apply(text, edits)
        var lines = t.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() {
            let s = l.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("p = Pondside(") || s.hasPrefix("p.play") || s.hasPrefix("p.stop") {
                lines[i] = "// " + l + "   // the patch's engine does this now: ~start.(0), ~stop.()"
            }
        }
        t = lines.joined(separator: "\n")
        return t
    }

    /// Handler blocks (`// @pondside cue` … `// @pondside end`) outside
    /// any `( … )` block, taken out of `text` for the cue section.
    static func takeHandlerBlocks(_ text: String) -> (rest: String, blocks: [String]) {
        let src = Source(text)
        var lines = text.components(separatedBy: "\n")
        var taken: [String] = []
        var remove: [Range<Int>] = []
        for b in HandlerSync.blocks(lines) where !src.blocks.contains(where: { $0.contains(src.offset(ofLine: b.header + 1)) }) {
            taken.append(lines[b.header...b.end].joined(separator: "\n") + "\n")
            remove.append(b.header..<(b.end + 1))
        }
        for r in remove.reversed() {
            lines.removeSubrange(r)
            if r.lowerBound < lines.count, lines[r.lowerBound].isEmpty { lines.remove(at: r.lowerBound) }
        }
        return (lines.joined(separator: "\n"), taken)
    }

    static func annotate(_ text: String, _ findings: [Finding]) -> String {
        var lines = text.components(separatedBy: "\n")
        let byLine = Dictionary(grouping: findings.filter { $0.line != nil }, by: { $0.line! })
        let src = Source(text)
        for (line, fs) in byLine where line - 1 < lines.count {
            // Not where the line ends inside a string or a /* comment */.
            let end = src.offset(ofLine: line) + lines[line - 1].utf16.count
            guard !src.tokens.contains(where: { ($0.kind == .string || ($0.kind == .comment && !src.text($0.range).hasPrefix("//")))
                && $0.range.lowerBound < end && $0.range.upperBound > end }) else { continue }
            lines[line - 1] += "   \(note) " + fs.map(\.message).joined(separator: "; ")
        }
        return lines.joined(separator: "\n")
    }

    static func replace(_ text: String, ranges: [Range<Int>], with new: String) -> String {
        apply(text, ranges.map { ($0, new) })
    }

    /// UTF-16 edits, applied back to front.
    static func apply(_ text: String, _ edits: [(Range<Int>, String)]) -> String {
        var u = Array(text.utf16)
        for (r, s) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            u.replaceSubrange(r, with: Array(s.utf16))
        }
        return String(decoding: u, as: UTF16.self)
    }

    // MARK: Reading a patch

    struct Source {
        let u: [UInt16]
        let tokens: [SCToken]
        /// Tokens that aren't whitespace or comments.
        let code: [SCToken]
        let blocks: [Range<Int>]
        let isPatch: Bool
        /// A file the patch loads: all of it runs, as if one block.
        let isDependency: Bool
        let engine: Range<Int>?
        let liveOnly: [Range<Int>]
        let lineStarts: [Int]
        /// Offsets of each `p.on(`, and each such statement through its `)`.
        let quarkCalls: [Int]
        let quarkStatements: [Range<Int>]

        init(_ text: String, dependency: Bool = false) {
            let u = Array(text.utf16)
            let code = SCLexer.tokenize(u).filter { $0.kind != .whitespace && $0.kind != .comment }
            let blocks = dependency ? [0..<u.count] : SCRegion.topLevelBlocks(in: text)
            isDependency = dependency
            let isPatch = text.contains(HandlerSync.patchMarker)
            func str(_ r: Range<Int>) -> String { String(decoding: u[r], as: UTF16.self) }
            func before(_ r: Range<Int>) -> String {
                // The line above the block's `(`.
                guard let nl = u[..<r.lowerBound].lastIndex(of: 0x0A) else { return "" }
                let start = u[..<nl].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
                return str(start..<nl)
            }
            self.u = u
            tokens = SCLexer.tokenize(u)
            self.code = code
            self.blocks = blocks
            self.isPatch = isPatch
            var starts = [0]
            for (i, c) in u.enumerated() where c == 0x0A { starts.append(i + 1) }
            lineStarts = starts
            engine = isPatch ? (blocks.first { before($0).hasPrefix("// 2. Engine") }
                ?? blocks.first { str($0).contains("~fireNow =") }) : nil
            liveOnly = blocks.filter { r in
                str((r.lowerBound + 1)..<(r.upperBound - 1))
                    .split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix(HandlerSync.liveOnlyMarker) } ?? false
            }
            let calls = code.indices.compactMap { k in
                k + 3 < code.count && str(code[k].range) == "p" && str(code[k + 1].range) == "."
                    && str(code[k + 2].range) == "on" && code[k + 3].kind == .openParen ? k : nil
            }
            quarkCalls = calls.map { code[$0].range.lowerBound }
            quarkStatements = calls.compactMap { k in
                SCRegion.matchingBracket(in: text, at: code[k + 3].range.lowerBound).map { code[k].range.lowerBound..<($0 + 1) }
            }
        }

        func text(_ r: Range<Int>) -> String { String(decoding: u[r], as: UTF16.self) }

        func line(_ offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }

        /// The UTF-16 offset where 1-based `line` starts.
        func offset(ofLine line: Int) -> Int { lineStarts[min(max(line - 1, 0), lineStarts.count - 1)] }

        func lineText(_ line: Int) -> String {
            let a = offset(ofLine: line)
            let b = line < lineStarts.count ? lineStarts[line] - 1 : u.count
            return text(a..<max(a, b))
        }

        /// Pondside's own code and live-only blocks: not the composer's to fix.
        func isExcluded(_ offset: Int) -> Bool {
            (engine?.contains(offset) ?? false) || liveOnly.contains { $0.contains(offset) }
        }

        /// Loose lines that are fine: the play lines, and the quark's own
        /// (handled by `migrate`).
        func isQuarkOrPlayLine(_ line: Int) -> Bool {
            let s = lineText(line).trimmingCharacters(in: .whitespaces)
            if ["~start.(", "~next.(", "~stop.(", "~go.(", "~triggerCue.("].contains(where: s.hasPrefix) { return true }
            if s.hasPrefix("p = Pondside(") || s.hasPrefix("p.play") || s.hasPrefix("p.stop") || s.hasPrefix("//") { return true }
            return quarkStatements.contains { $0.contains(offset(ofLine: line)) || $0.contains(offset(ofLine: line) + max(0, lineText(line).utf16.count - 1)) }
        }

        /// Whether a loose line defines something: a SynthDef, buffer, bus or
        /// group, an environment variable, a loaded file, a Pdef/Ndef/Tdef.
        func definesSomething(line: Int) -> Bool {
            let t = lineText(line).trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") { return false }
            let defs = ["SynthDef(", "Buffer.", "Bus.", "Group.", ".load", ".loadRelative", "Pdef(", "Ndef(", "Tdef(", "OSCdef(", "MIDIdef("]
            if defs.contains(where: t.contains) { return true }
            // ~x = …, but not ~x == … or ~x.set(…)
            if let r = t.range(of: #"^~\w+\s*=[^=]"#, options: .regularExpression) { return !r.isEmpty }
            return false
        }

        /// Paths loaded outside live-only blocks: `"p".resolveRelative.load`,
        /// `"p".loadRelative`, `load("p")`.
        var loads: [String] {
            code.indices.compactMap { k -> String? in
                guard code[k].kind == .string, !isExcluded(code[k].range.lowerBound) else { return nil }
                let lit = String(text(code[k].range).dropFirst().dropLast())
                func word(_ i: Int) -> String { i < code.count && i >= 0 ? text(code[i].range) : "" }
                if word(k + 1) == ".", word(k + 2) == "resolveRelative", word(k + 3) == ".", word(k + 4) == "load" { return lit }
                if word(k + 1) == ".", word(k + 2) == "loadRelative" { return lit }
                if word(k - 1) == "(", word(k - 2) == "load" { return lit }
                return nil
            }
        }

        /// Relative paths in string literals used with `.resolveRelative`,
        /// `.loadRelative` or `load(…)`: each literal's range (quotes included)
        /// and its text.
        var relativePaths: [(Range<Int>, String)] {
            code.indices.compactMap { k -> (Range<Int>, String)? in
                guard code[k].kind == .string else { return nil }
                let lit = String(text(code[k].range).dropFirst().dropLast())
                guard !lit.isEmpty, !lit.hasPrefix("/"), !lit.hasPrefix("~") else { return nil }
                func word(_ i: Int) -> String { i < code.count && i >= 0 ? text(code[i].range) : "" }
                let used = (word(k + 1) == "." && ["resolveRelative", "loadRelative"].contains(word(k + 2)))
                    || (word(k - 1) == "(" && word(k - 2) == "load")
                return used ? (code[k].range, lit) : nil
            }
        }

        /// `SoundIn.ar(0)`, outside Pondside's own code.
        var soundInZero: [Range<Int>] {
            code.indices.compactMap { k in
                guard k + 5 < code.count, text(code[k].range) == "SoundIn", text(code[k + 1].range) == ".",
                      text(code[k + 2].range) == "ar", code[k + 3].kind == .openParen,
                      text(code[k + 4].range) == "0", code[k + 5].kind == .closeParen,
                      !(engine?.contains(code[k].range.lowerBound) ?? false) else { return nil }
                return code[k].range.lowerBound..<code[k + 5].range.upperBound
            }
        }

        var environmentNames: Set<String> {
            Set(code.filter { $0.kind == .environment }.map { String(text($0.range).dropFirst()) })
        }

        /// Environment variables of the composer's that the engine defines.
        var collisions: [SCToken] {
            code.filter { $0.kind == .environment && PatchMigration.engineNames.contains(String(text($0.range).dropFirst())) }
        }

        /// The value of `~key = "…";` in the engine block.
        func engineValue(_ key: String) -> String? {
            guard let e = engine else { return nil }
            let body = text(e)
            guard let r = body.range(of: "~\(key) = \""), let end = body[r.upperBound...].firstIndex(of: "\"") else { return nil }
            return String(body[r.upperBound..<end])
        }
    }
}

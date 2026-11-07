import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon
import PondsideBridge

// `pondside` — the headless command-line surface. Links only portable
// modules, so it runs on any platform Swift does.

let usage = """
usage: pondside <command> [options]

commands:
  render <file.ly> [--format pdf|svg|png] [--out <dir>] [--json]
      Engrave for export. Point-and-click is always disabled, and the output
      is checked for local filesystem paths before it is written.
  check <file.ly> [--json]
      Compile and report diagnostics. Exit status 1 if there are errors.
  links <file.svg> [--json]
      List the point-and-click links in a canvas SVG with their bounds.
  doctor [--json]
      List every LilyPond installation found, with version and origin.
  cues <file.ly> [--format json|cues|marks|ec|collections] [--rate <hz>] [--out <file>]
      Every \\ecue with its moment, bar, beat, seconds and samples, timed
      exactly as LilyPond's MIDI plays (hidden \\playTempo included).
      --format cues writes the piece.cues lines SuperCollider loaders read;
      marks the \\timingMark lines starting with --prefix (default improv);
      ec the \\collection pitch classes on --staff (default elecUp) as ~ec;
      collections every staff's as ~collections (render writes it too).
  handlers <file.ly> [--scd <patch.scd>] [--rate <hz>]
      Create or update the score's patch (patch/<name>.scd) with one handler
      per cue, and its engine (patch/dependencies/pondside.scd). New
      cues get stubs; cues that left the score are commented out; code
      inside a handler is never changed.
  lexicon list | search <words> | show <id> | impl <id> [--project <dir>]
      The Lexicon in three tiers: list is tier 0 (index.json), show is
      tier 1 (entry.toml and README), impl is tier 2 (the implementation).
  lexicon check <file.ly> | include <file.ly> | lock <file.ly>
      check finds \\lexicon and \\startGraphic uses with unknown entries or bad
      params, in every file of the score; include writes lexicon.ily, which
      defines them; lock records the versions used in the score.
  lexicon drafts | promote <id> [--to user] | discard <id> [--project <dir>]
      Entries an agent proposed: list them, accept one into the project's
      (or your) Lexicon, or delete it. Only people promote drafts.
  history <file.ly> [--show <rev> [--file <f>]] [--restore <rev>]
      Pondside's checkpoints of the score's files (kept apart from your own
      git repository): list them, print a file at one, or restore one
      (the current state is checkpointed first).
  mix <file.ly> [--scd <patch.scd>] [--out <file.wav>]
      Render the score's Pondside patch (pondside handlers starts one) offline
      in mockup mode against the mockup: the score with its electronics, in
      <name>.mix.wav. The app runs it after each mockup.
  patch <file.ly> [--scd <patch.scd>] [--from <file.scd>] [--fix [--agent auto|claude|opencode|codex]]
      Check the score's SuperCollider patch (or, without one, the folder's
      likeliest .scd) against Pondside's patch layout (docs/SUPERCOLLIDER.md).
      --fix migrates it into <name>.scd: wraps it in the mode, engine, cue and
      play sections, converts quark handlers, renames clashing names, feeds
      SoundIn.ar(0) from ~live, and marks what is left with // pondside:
      comments for an agent (skill sc-patch-migration). An original that is
      rewritten is kept as <name>.before-pondside.scd. --agent then has
      claude -p or opencode run fix the marked lines, unattended.
  mockup <file.ly> [--out <file.wav>] [--rate <hz>] [--renderer musescore|fluidsynth] [--soundfont <sf2>] [--stems]
         [--timing <file>]
      Render the score's playback to audio for the patch to play cues
      against: MuseScore 4 (Muse Sounds) first, fluidsynth as the fallback.
      A score without its own \\midi block gets one generated: repeats,
      tremolos and trills played out, \\articulate, instruments from staff
      names, electronics staves silent. Silent renders and wrong sample
      rates are refused. The file is padded with silence to the score's end
      mark. Beside it, piece.cues: the cue times of the same compile
      (seconds<TAB>bar<TAB>cue N), what the Pondside quark reads. --stems
      also writes one file per staff (piece-<staff>.wav), to mute live
      parts. --timing writes the timing rows of the same compile.
  completion zsh|bash
      Print a completion script: eval "$(pondside completion zsh)".
  rpc <method> [<json params>]
      Call the running app over its socket, e.g. pondside rpc app.documents,
      pondside rpc document.select '{"path":"score.ly","line":12,"character":4}'.
  mcp [--project <dir>]
      Serve the Model Context Protocol on stdin/stdout: tools (check, query,
      render, cues, lexicon_check) and the Lexicon tiers as resources.
      Claude Code: claude mcp add pondside -- pondside mcp
  agents [<dir>]
      Write .mcp.json (Claude Code), opencode.json (opencode), and
      .codex/config.toml (Codex) in the
      folder (default: the current one), so an agent started there finds
      pondside mcp. Existing files only gain a missing pondside server.
      The app does this for each score's folder when it opens the score.
  timeline <file.ly> [--json]
      The tempo map: each tempo step's moment, seconds and quarter notes per minute.
  watch <file> --on-change <command>
      Run a shell command whenever the file's content changes.
  version
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: ArraySlice<String>, valued: Set<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard let v = it.next() else { throw CLIError("--\(name) needs a value") }
                    options[name] = v
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func resolveLilyPond(for source: URL?) async throws -> LilyPondInstallation {
    let installs = await ToolchainDetector().detectLilyPond()
    // The project's pin (pondside.toml) wins over the score's \version.
    let pinned = source.flatMap { try? ProjectConfig.find(from: $0) }?.lilypondVersion.flatMap { LilyPondVersion($0) }
    let declared = pinned ?? source.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(LilyPondVersion.declared(in:))
    guard let chosen = ToolchainDetector.select(from: installs, for: declared) else {
        throw CLIError("no LilyPond found. Run the Pondside installer, install it (e.g. `brew install lilypond`) or set PONDSIDE_LILYPOND.")
    }
    if let declared, chosen.version != declared {
        printErr("note: score declares \\version \"\(declared)\"; using LilyPond \(chosen.version) at \(chosen.executable)")
    }
    return chosen
}

func sourceURL(_ args: Arguments) throws -> URL {
    guard let path = args.positional.first else { throw CLIError("missing file argument") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError("no such file: \(path)") }
    return url
}

func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

struct DiagnosticJSON: Encodable {
    var severity: String
    var message: String
    var file: String?
    var line: Int?
    var column: Int?
}

extension DiagnosticJSON {
    init(_ d: Diagnostic) {
        self.init(severity: d.severity.rawValue, message: d.message, file: d.file, line: d.line, column: d.column)
    }
}

func render(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    guard let format = ExportFormat(rawValue: args.options["format"] ?? "pdf") else {
        throw CLIError("unknown format \(args.options["format"]!); expected pdf, svg or png")
    }
    let outDir = URL(fileURLWithPath: args.options["out"] ?? source.deletingLastPathComponent().path).standardizedFileURL
    let engraver = LilyPondEngraver(installation: try await resolveLilyPond(for: source))
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }

    let result = try await engraver.engrave(source, purpose: .export(format), outputDirectory: scratch)
    for d in result.diagnostics { printErr(DiagnosticFormatter.line(d)) }
    guard result.succeeded else {
        printErr("render failed (exit \(result.exitStatus))")
        return 1
    }
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var written: [String] = []
    for file in result.outputFiles {
        let dest = outDir.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: file, to: dest)
        written.append(dest.path)
    }
    if args.flags.contains("json") {
        try printJSON(["files": written])
    } else {
        written.forEach { print($0) }
    }
    return 0
}

func check(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let engraver = LilyPondEngraver(installation: try await resolveLilyPond(for: source))
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: scratch)
    // Systems running into the right margin while automatic line breaks are off.
    let overflows = SystemOverflow.applies(toSources: SourceGraph.load(root: source).files.map(\.text))
        ? SystemOverflow.detect(in: result.outputFiles.compactMap { try? Data(contentsOf: $0) }.map(EngravedPage.init(svg:)))
        : []
    if args.flags.contains("json") {
        struct OverflowJSON: Encodable {
            var page: Int
            var mm_past_margin: Double
            var file: String?
            var line: Int?
        }
        struct Report: Encodable {
            var ok: Bool
            var pages: Int
            var milliseconds: Int
            var diagnostics: [DiagnosticJSON]
            var overflows: [OverflowJSON]
            var log: String?
        }
        let ms = Int(result.duration.components.seconds * 1000 + result.duration.components.attoseconds / 1_000_000_000_000_000)
        let ok = result.errors.isEmpty && result.succeeded
        try printJSON(Report(ok: ok, pages: result.outputFiles.count,
                             milliseconds: ms, diagnostics: result.diagnostics.map(DiagnosticJSON.init),
                             overflows: overflows.map { OverflowJSON(page: $0.page + 1, mm_past_margin: ($0.amountMM * 10).rounded() / 10,
                                                                     file: $0.first?.path, line: $0.first?.line) },
                             log: ok ? nil : CompilerLog.tail(result.messages)))
    } else {
        for d in result.diagnostics { print(DiagnosticFormatter.line(d)) }
        for o in overflows {
            let at = o.first.map { "\($0.path):\($0.line): " } ?? ""
            print(String(format: "%@warning: system on page %d runs %.1f mm into the right margin (line breaks are off: move a bar or narrow it)",
                         at, o.page + 1, o.amountMM))
        }
        let ok = result.errors.isEmpty && result.succeeded
        if !ok {
            let tail = CompilerLog.tail(result.messages)
            if !tail.isEmpty { print(tail) }
        }
        print(ok ? "clean" : "\(result.errors.count) error(s)")
    }
    return result.errors.isEmpty && result.succeeded ? 0 : 1
}

func links(_ args: Arguments) throws -> Int32 {
    guard let path = args.positional.first else { throw CLIError("missing file argument") }
    let page = EngravedPage(svg: try Data(contentsOf: URL(fileURLWithPath: path)))
    struct Link: Encodable {
        var file: String
        var line: Int
        var character: Int
        var bounds: Rect
    }
    let all = page.graphics.compactMap { g in
        g.link.map { Link(file: $0.path, line: $0.line, character: $0.character, bounds: g.bounds) }
    }
    if args.flags.contains("json") {
        try printJSON(all)
    } else {
        for l in all {
            print("\(l.file):\(l.line):\(l.character)\t\(String(format: "%.2f,%.2f %.2fx%.2f", l.bounds.x, l.bounds.y, l.bounds.width, l.bounds.height))")
        }
    }
    return 0
}

func doctor(_ args: Arguments) async throws -> Int32 {
    let installs = await ToolchainDetector().detectLilyPond()
    if args.flags.contains("json") {
        try printJSON(installs)
    } else if installs.isEmpty {
        print("LilyPond: not found")
    } else {
        for i in installs {
            print("LilyPond \(i.version)\t\(i.origin.rawValue)\t\(i.executable)")
        }
    }
    return installs.isEmpty ? 1 : 0
}

func watch(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    guard let command = args.options["on-change"] else { throw CLIError("watch needs --on-change <command>") }
    let watcher = FileWatcher(url: source) { _ in
        do {
            let out = try ProcessRunner.runBlocking("/bin/sh", ["-c", command])
            FileHandle.standardOutput.write(out.stdout)
            FileHandle.standardError.write(out.stderr)
        } catch {
            printErr("\(error)")
        }
    }
    watcher.start()
    printErr("watching \(source.path) — Ctrl-C to stop")
    while true { try await Task.sleep(for: .seconds(3600)) }
}

func cueSheet(_ args: Arguments) async throws -> CueSheet {
    try await timing(args).sheet
}

func timing(_ args: Arguments) async throws -> (sheet: CueSheet, log: TimingLog) {
    let source = try sourceURL(args)
    let lily = try await resolveLilyPond(for: source)
    let config = try ProjectConfig.find(from: source)
    let rate = try args.options["rate"].map { r -> Int in
        guard let v = Int(r), v > 0 else { throw CLIError("--rate needs a sample rate in Hz") }
        return v
    } ?? config.sampleRate
    let log = try await TimingDump.run(lily, source: source)
    let lex = Lexicon.load(Lexicon.standardScopes(project: source.deletingLastPathComponent()))
    return (CueSheet(log: log, score: source.lastPathComponent, sampleRate: rate,
                     soundParams: { lex.soundParams(entry: $0, params: $1, beatDur: $2, spanDur: $3, tempo: $4) }), log)
}

func cues(_ args: Arguments) async throws -> Int32 {
    let (sheet, log) = try await timing(args)
    for w in sheet.warnings { printErr("warning: \(w)") }
    let data: Data
    switch args.options["format"] ?? "json" {
    case "json": data = try sheet.json() + Data("\n".utf8)
    case "cues": data = Data(sheet.cuesText.utf8)
    case "marks":
        let prefix = args.options["prefix"] ?? "improv"
        data = Data(sheet.marks.filter { $0.text.hasPrefix(prefix) }
            .map { String(format: "%.3f", $0.seconds) + "\t\($0.position.measure)\t\($0.text)\n" }.joined().utf8)
    case "ec":
        let staff = args.options["staff"] ?? "elecUp"
        data = Data(Collections.scd(Collections.find(in: log, staff: staff), staff: staff, score: sheet.score).utf8)
    case "collections":
        data = Data(Collections.collectionsSCD(Collections.all(in: log), score: sheet.score).utf8)
    case let f: throw CLIError("unknown format '\(f)' (json, cues, marks, ec, collections)")
    }
    if let out = args.options["out"] {
        try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    } else {
        FileHandle.standardOutput.write(data)
    }
    return 0
}

func handlers(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let config = try ProjectConfig.find(from: source)
    let url = args.options["scd"].map { URL(fileURLWithPath: $0) } ?? PatchMigration.patchURL(score: source, configured: config.handlers)
    let sheet = try await cueSheet(args)
    for w in sheet.warnings { printErr("warning: \(w)") }
    let name = source.deletingPathExtension().lastPathComponent
    if let existing = try? String(contentsOf: url, encoding: .utf8) {
        let (text, report) = HandlerSync.sync(existing, with: sheet,
                                              quark: (source.deletingLastPathComponent().appendingPathComponent(HandlerSync.Layout.renders).path, name))
        if text != existing { try Data(text.utf8).write(to: url, options: .atomic) }
        for (what, ids) in [("added", report.added), ("moved", report.moved), ("restored", report.restored),
                            ("commented out", report.orphaned)] where !ids.isEmpty {
            print("\(what): \(ids.joined(separator: ", "))")
        }
        if text == existing { print("\(url.lastPathComponent) is up to date") }
    } else {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(HandlerSync.patchStarter(sheet, name: name).utf8).write(to: url, options: .atomic)
        print("wrote \(url.lastPathComponent): a patch with \(sheet.cues.count) cue stubs")
    }
    if existingIsPatch(url), try PatchMigration.ensureEngine(patch: url, name: name) {
        print("wrote \(HandlerSync.Layout.engineFile)")
    }
    return 0
}

func existingIsPatch(_ url: URL) -> Bool {
    (try? String(contentsOf: url, encoding: .utf8))?.contains(HandlerSync.patchMarker) == true
}

func lexiconCommand(_ args: Arguments) throws -> Int32 {
    guard let sub = args.positional.first else {
        throw CLIError("lexicon needs list, search, show, impl, check, include, drafts, promote, discard or lock")
    }
    let target = args.positional.dropFirst().first
    let scoreDir = target.flatMap { t -> URL? in
        t.hasSuffix(".ly") || t.hasSuffix(".ily") ? URL(fileURLWithPath: t).deletingLastPathComponent() : nil
    }
    let project = args.options["project"].map { URL(fileURLWithPath: $0) } ?? scoreDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let lex = Lexicon.load(Lexicon.standardScopes(project: project))
    for p in lex.problems { printErr("lexicon: \(p)") }
    switch sub {
    case "list":
        print(lex.indexJSON(), terminator: "")
    case "show", "impl":
        guard let id = target else { throw CLIError("lexicon \(sub) needs an entry id") }
        guard let text = sub == "show" ? lex.tier1(id) : lex.tier2(id) else { throw CLIError("no Lexicon entry \(id)") }
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
    case "search":
        let query = args.positional.dropFirst().joined(separator: " ")
        for line in lex.search(query, limit: 20) { print(line) }
    case "check", "include", "lock":
        guard let path = target else { throw CLIError("lexicon \(sub) needs a score") }
        // Every file of the score: uses in included parts count too.
        let graph = SourceGraph.load(root: URL(fileURLWithPath: path).standardizedFileURL)
        if sub == "check" {
            var bad = false
            for warning in LexiconLock.drift(in: graph.files.first?.text ?? "", lexicon: lex) { print("\(path): \(warning)") }
            for f in graph.files {
                for p in lex.check(f.text) { print("\(f.url.path):\(p.line): \(p.message)"); bad = true }
            }
            return bad ? 1 : 0
        }
        let used = Set(graph.files.flatMap { LexiconUse.find(in: $0.text).map(\.id) })
        if sub == "lock" {
            // The versions this score uses, written into the root so it resolves them later.
            let root = URL(fileURLWithPath: path)
            let text = try String(contentsOf: root, encoding: .utf8)
            try Data(LexiconLock.updating(text, lexicon: lex, used: used).utf8).write(to: root, options: .atomic)
            print("locked \(used.count) entr\(used.count == 1 ? "y" : "ies") in \(root.lastPathComponent)")
            return 0
        }
        let out = args.options["out"] ?? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("lexicon.ily").path
        try Data(lex.includeFile(for: used).utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
        print("wrote \(out) for \(used.count) entr\(used.count == 1 ? "y" : "ies")")
    case "drafts":
        let drafts = lex.entries.values.filter { $0.scope == .draft }.sorted { $0.entry.id < $1.entry.id }
        if drafts.isEmpty { print("No drafts in \(Lexicon.draftsDirectory(project: project).path)") }
        for d in drafts { print("\(d.entry.id)\t\(d.entry.version)\t\(d.entry.gloss)") }
    case "promote":
        guard let id = target else { throw CLIError("lexicon promote needs a draft id") }
        let scope: Lexicon.Scope = args.options["to"] == "user" ? .user : .project
        let dir = try Lexicon.promote(id: id, project: project, to: scope)
        print("accepted \(id) into \(dir.path)")
    case "discard":
        guard let id = target else { throw CLIError("lexicon discard needs a draft id") }
        try Lexicon.discard(id: id, project: project)
        print("discarded the draft \(id)")
    default:
        throw CLIError("unknown lexicon command '\(sub)'")
    }
    return 0
}

func historyCommand(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Pondside/History", isDirectory: true) else { throw CLIError("no Application Support folder") }
    let history = ShadowHistory(score: source, root: root)
    if let rev = args.options["show"] {
        let file = args.options["file"].map { URL(fileURLWithPath: $0) } ?? source
        print(try await history.text(of: file, at: rev), terminator: "")
        return 0
    }
    if let rev = args.options["restore"] {
        let files = SourceGraph.load(root: source).files.map(\.url)
        try await history.checkpoint(files, message: "before restoring \(rev)")
        for f in files {
            guard let text = try? await history.text(of: f, at: rev) else { continue }
            try Data(text.utf8).write(to: f, options: .atomic)
            print("restored \(f.lastPathComponent) from \(rev)")
        }
        return 0
    }
    let checkpoints = try await history.checkpoints()
    if checkpoints.isEmpty { print("No checkpoints yet: Pondside makes them as you edit.") }
    for c in checkpoints { print("\(c.revision)\t\(c.date)\t\(c.message)") }
    return 0
}

/// The score with its electronics: the Pondside patch rendered offline in
/// mockup mode against the mockup (PatchRender), into <name>.mix.wav.
func mix(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let config = try ProjectConfig.find(from: source)
    let configured = args.options["scd"].map { URL(fileURLWithPath: $0) } ?? config.handlers
    guard let patch = PatchRender.patch(for: source, configured: configured) else {
        throw CLIError("no Pondside patch for \(source.lastPathComponent): `pondside handlers \(source.lastPathComponent) --scd \(source.deletingPathExtension().lastPathComponent).scd` starts one")
    }
    let wav = HandlerSync.Layout.mockup(score: source)
    guard FileManager.default.fileExists(atPath: wav.path) else { throw CLIError("no mockup yet (renders/\(wav.lastPathComponent)): run pondside mockup first") }
    guard let sclang = SuperColliderToolchain.findSclang(configured: config.sclang?.path) else {
        throw CLIError("SuperCollider not found (install it, or set [supercollider] path in pondside.toml)")
    }
    let out = args.options["out"].map { URL(fileURLWithPath: $0) } ?? PatchRender.output(for: source)
    let problems = try await PatchRender.render(sclang: sclang, patch: patch, wav: wav, out: out)
    for p in problems { printErr("warning: " + p) }
    print("\(out.path): \(patch.lastPathComponent) in mockup mode")
    return 0
}

/// Audits the score's SuperCollider patch (or, without one, the folder's
/// likeliest .scd) against Pondside's patch layout; --fix migrates it.
func patchCommand(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let config = try ProjectConfig.find(from: source)
    let configured = args.options["scd"].map { URL(fileURLWithPath: $0) } ?? config.handlers
    let target = PatchMigration.patchURL(score: source, configured: configured)
    let found: (source: URL, target: URL, findings: [PatchMigration.Finding])?
    if let from = args.options["from"].map({ URL(fileURLWithPath: $0) }) {
        found = (from, target, PatchMigration.audit(try String(contentsOf: from, encoding: .utf8)))
    } else {
        found = PatchMigration.candidate(score: source, configured: configured)
    }
    guard let c = found else {
        let marks = PatchMigration.allMarks(patch: target)
        if !FileManager.default.fileExists(atPath: target.path) { print("no SuperCollider patch beside \(source.lastPathComponent)") }
        else if marks.isEmpty { print("\(target.lastPathComponent) is a Pondside patch with nothing to fix") }
        else { print("marked lines still to fix:"); for m in marks { print("  \(m.file):\(m.line): \(m.text)") } }
        return marks.isEmpty ? 0 : 1
    }
    func show(_ f: PatchMigration.Finding, in file: URL) -> String {
        let name = f.file ?? file.lastPathComponent
        return (f.line.map { "\(name):\($0): " } ?? "\(name): ") + f.message
    }
    guard args.flags.contains("fix") else {
        if args.flags.contains("json") {
            struct Item: Encodable { var kind: String; var line: Int?; var message: String; var automatic: Bool }
            struct Report: Encodable { var source: String; var target: String; var findings: [Item] }
            try printJSON(Report(source: c.source.path, target: c.target.path, findings: c.findings.map {
                Item(kind: $0.kind.rawValue, line: $0.line, message: $0.message, automatic: $0.automatic)
            }))
            return 1
        }
        let auto = c.findings.filter(\.automatic), manual = c.findings.filter { !$0.automatic }
        if !auto.isEmpty { print("pondside patch --fix does these:"); for f in auto { print("  " + show(f, in: c.source)) } }
        if !manual.isEmpty { print("for you or an agent (skill sc-patch-migration):"); for f in manual { print("  " + show(f, in: c.source)) } }
        return 1
    }
    let sheet = try? await cueSheet(args)
    let (result, backup, moved) = try PatchMigration.write(score: source, source: c.source, target: c.target, sheet: sheet)
    for m in moved { print("moved \(m)") }
    if let backup { print("kept the original as patch/\(backup.lastPathComponent)") }
    print("wrote \(c.target.lastPathComponent)")
    for f in result.applied { print("  done: " + f.message) }
    if !result.manual.isEmpty {
        print("left for you or an agent, marked \(PatchMigration.note) (skill sc-patch-migration):")
        for f in result.manual { print("  " + show(f, in: c.target)) }
    }
    guard !result.manual.isEmpty, let preference = args.options["agent"] else { return 0 }
    guard let agent = AgentRun.choose(preference: preference == "auto" ? nil : preference) else {
        throw CLIError("no agent found (claude, opencode or codex)")
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let pondside = FileManager.default.isExecutableFile(atPath: me) ? me : "pondside"
    print("\(agent.harness.title) is finishing \(c.target.lastPathComponent)…")
    let outcome = try await agent.run(prompt: AgentRun.migrationPrompt(score: source, patch: c.target),
                                      folder: source.deletingLastPathComponent(), pondside: pondside, role: .patch) { printErr("  " + $0) }
    print(outcome.summary)
    if let cost = outcome.costUSD { print(String(format: "(%@: $%.2f)", agent.harness.title, cost)) }
    let now = (try? String(contentsOf: c.target, encoding: .utf8)) ?? ""
    let left = PatchMigration.audit(now) + PatchMigration.auditDependencies(of: c.target)
    let marks = PatchMigration.allMarks(patch: c.target).count
    print(left.isEmpty && marks == 0 ? "\(c.target.lastPathComponent) is a Pondside patch" : "\(marks) marks and \(left.count) findings left")
    return outcome.failed ? 1 : 0
}

func mockup(_ args: Arguments) async throws -> Int32 {
    let source = try sourceURL(args)
    let lily = try await resolveLilyPond(for: source)
    let config = try ProjectConfig.find(from: source)
    let rate = args.options["rate"].flatMap { Int($0) } ?? config.sampleRate
    let only = try (args.options["renderer"] ?? config.renderer).map { r -> MockupRenderer.Renderer in
        guard let v = MockupRenderer.Renderer(rawValue: r) else { throw CLIError("--renderer is musescore or fluidsynth") }
        return v
    }
    let scratch = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    // One compile gives the MIDI and the timing of the same music: the
    // score's own \midi, else the playback Pondside generates (PlaybackScore).
    let playback = try await PlaybackScore.compile(lily, source: source, midi: scratch.appendingPathComponent("playback.midi"))
    if let path = args.options["timing"] {
        try Data(playback.timingText.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    guard let midi = playback.midi else { throw CLIError("no MIDI was written: the score has no music to play") }
    let out = URL(fileURLWithPath: args.options["out"]
        ?? HandlerSync.Layout.mockup(score: source).path)
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let renderer = MockupRenderer(sampleRate: rate, soundFont: args.options["soundfont"].map { URL(fileURLWithPath: $0) } ?? config.soundFont)
    // The piece lasts until its `end` mark, which may be after the last note.
    let end = playback.timing.end.map { TempoMap(playback.timing).seconds(at: $0) }
    func finish(_ file: URL, _ used: MockupRenderer.Renderer, _ info: WAVInfo) {
        var seconds = info.seconds
        if let end, (try? AudioFiles.padWAV(file, toSeconds: end)) == true { seconds = end }
        print("\(file.path): \(String(format: "%.1f", seconds)) s at \(info.sampleRate) Hz via \(used.rawValue), peak \(String(format: "%.1f", 20 * log10(info.peak))) dBFS")
    }
    // The cue times of this very render beside it (piece.wav, piece.cues),
    // where the Pondside quark reads both, so they cannot disagree; written
    // first, so a missing renderer still leaves the times.
    let sheet = CueSheet(log: playback.timing, score: source.lastPathComponent, sampleRate: rate)
    if !sheet.cues.isEmpty {
        let cues = out.deletingPathExtension().appendingPathExtension("cues")
        // Rewritten only when the times change: the app re-renders the mix when it does.
        if (try? String(contentsOf: cues, encoding: .utf8)) != sheet.cuesText {
            try Data(sheet.cuesText.utf8).write(to: cues, options: .atomic)
        }
        print("\(cues.path): \(sheet.cues.count) cues")
    }
    // The score's pitch collections beside them (renders/<name>.collections.scd):
    // the engine loads them as ~collections. Rewritten only when they change;
    // removed when the score has none.
    let collectionsURL = out.deletingPathExtension().appendingPathExtension("collections.scd")
    let found = Collections.all(in: playback.timing)
    if found.isEmpty {
        try? FileManager.default.removeItem(at: collectionsURL)
    } else {
        let text = Collections.collectionsSCD(found, score: source.lastPathComponent)
        if (try? String(contentsOf: collectionsURL, encoding: .utf8)) != text {
            try Data(text.utf8).write(to: collectionsURL, options: .atomic)
        }
        print("\(collectionsURL.path): \(found.count) collections")
    }
    // Passages the MIDI can't play (improvisations), at their marks.
    let partsDirs = MockupParts.folders(score: source, configured: config.parts)
    // Nothing audible changed (a graphic, the legend, a comment): the same
    // MIDI, cues, parts and settings as the last render leave its WAV as it
    // is, so the app sees no new mockup and doesn't render the mix again.
    func stamp(_ u: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        return "\(u.path):\((a?[.size] as? Int) ?? 0):\(((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
    }
    let parts = config.hook == nil ? MockupParts.find(marks: sheet.marks, folders: partsDirs) : []
    let soundKey = ContentHash(bytes: (try? Data(contentsOf: midi)) ?? Data()).description + "|" + ContentHash(sheet.cuesText).description
        + "|\(rate)|\(only?.rawValue ?? "auto")|\(renderer.soundFont?.path ?? "")|\(end.map { String($0) } ?? "")|"
        + (config.hook.map(stamp) ?? "") + "|" + parts.map { stamp($0.file) + "@\($0.start)" }.joined(separator: ",")
        + (args.flags.contains("stems") ? "|stems" : "")
    let keyFile = out.deletingPathExtension().appendingPathExtension("mockup-key")
    if FileManager.default.fileExists(atPath: out.path), (try? String(contentsOf: keyFile, encoding: .utf8)) == soundKey,
       !args.flags.contains("force") {
        print("\(out.path): unchanged (same MIDI, cues and parts; --force renders anyway)")
        return 0
    }
    try? FileManager.default.removeItem(at: keyFile)
    let (used, info) = try await renderer.render(midi: midi, to: out, only: only)
    finish(out, used, info)
    if let hook = config.hook {
        guard let sclang = SuperColliderToolchain.findSclang(configured: config.sclang?.path) else {
            throw CLIError("[audio] hook needs SuperCollider (not found)")
        }
        try await MockupParts.runHook(sclang: sclang, hook: hook, wav: out, marks: sheet.marks, prefix: config.hookMarks,
                                      partsDir: partsDirs[0])
        print("\(out.lastPathComponent): \(hook.lastPathComponent) rendered the \(config.hookMarks) parts into it")
    } else {
        if !parts.isEmpty {
            try MockupParts.mix(parts, into: out)
            print("\(out.lastPathComponent): mixed in " + parts.map { "\($0.file.lastPathComponent) at \(String(format: "%.1f", $0.start)) s" }.joined(separator: ", "))
        }
    }
    // --stems: one file per staff, so a patch can mute the parts played live.
    if args.flags.contains("stems"), let data = try? Data(contentsOf: midi), let (_, tracks) = AudioFiles.midiTracks(data) {
        for i in tracks.indices.dropFirst() {
            guard let stem = AudioFiles.midi(data, keepingTrack: i) else { continue }
            // LilyPond names a track "staff:voice"; the staff names the stem.
            let staff = tracks[i].name.split(separator: ":").first.map(String.init) ?? ""
            let name = staff.isEmpty ? "track\(i)" : staff.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
            let stemMidi = scratch.appendingPathComponent("stem-\(i).midi")
            try stem.write(to: stemMidi)
            let file = URL(fileURLWithPath: out.deletingPathExtension().path + "-\(name).wav")
            do {
                let (u, inf) = try await renderer.render(midi: stemMidi, to: file, only: only)
                finish(file, u, inf)
            } catch where "\(error)".contains("silence") {
                print("stem \(name): no sound (skips only), not written")
            } catch {
                printErr("stem \(name): \(error)")
            }
        }
    }
    // Written last: a render that failed part-way renders again next time.
    try? Data(soundKey.utf8).write(to: keyFile, options: .atomic)
    return 0
}

let completionCommands = ["render", "check", "cues", "timeline", "handlers", "mockup", "mix", "rpc", "lexicon", "links", "doctor", "watch", "mcp",
                          "agents", "completion", "version", "help"]

func completion(_ args: Arguments) throws -> Int32 {
    let commands = completionCommands.joined(separator: " ")
    switch args.positional.first {
    case "zsh":
        print("""
        #compdef pondside
        _pondside() {
          local -a commands
          commands=(\(commands))
          if (( CURRENT == 2 )); then
            _describe 'command' commands
          elif [[ $words[2] == lexicon && CURRENT == 3 ]]; then
            _values 'lexicon command' list show impl check include
          elif [[ $words[2] == lexicon && ( $words[3] == show || $words[3] == impl ) ]]; then
            local -a ids
            ids=(${(f)"$(pondside lexicon list 2>/dev/null | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')"})
            _describe 'entry' ids
          elif [[ $words[2] == completion ]]; then
            _values 'shell' zsh bash
          else
            _arguments '*:file:_files -g "*.(ly|ily|svg)"' '--format[output format]:format:(pdf svg png json cues)' \\
              '--out[output path]:path:_files' '--json[JSON output]' '--rate[sample rate]:rate:(44100 48000 96000)' \\
              '--scd[SuperCollider file]:file:_files -g "*.scd"' '--project[project folder]:dir:_files -/'
          fi
        }
        compdef _pondside pondside
        """)
    case "bash":
        print("""
        _pondside() {
          local cur=${COMP_WORDS[COMP_CWORD]}
          if [[ $COMP_CWORD -eq 1 ]]; then
            COMPREPLY=($(compgen -W "\(commands)" -- "$cur"))
          elif [[ ${COMP_WORDS[1]} == lexicon && $COMP_CWORD -eq 2 ]]; then
            COMPREPLY=($(compgen -W "list show impl check include" -- "$cur"))
          elif [[ ${COMP_WORDS[1]} == completion ]]; then
            COMPREPLY=($(compgen -W "zsh bash" -- "$cur"))
          elif [[ $cur == --* ]]; then
            COMPREPLY=($(compgen -W "--format --out --json --rate --scd --project --on-change" -- "$cur"))
          else
            COMPREPLY=($(compgen -f -- "$cur"))
          fi
        }
        complete -o filenames -F _pondside pondside
        """)
    default:
        throw CLIError("completion needs zsh or bash")
    }
    return 0
}

func timeline(_ args: Arguments) async throws -> Int32 {
    let sheet = try await cueSheet(args)
    if args.flags.contains("json") {
        try printJSON(sheet.tempo)
    } else {
        for t in sheet.tempo {
            print("\(t.moment)\t" + String(format: "%.3f", t.seconds) + "\t\(t.bpm)")
        }
        if let d = sheet.duration { print("end\t" + String(format: "%.3f", d)) }
    }
    return 0
}

enum DiagnosticFormatter {
    static func line(_ d: Diagnostic) -> String {
        var loc = ""
        if let file = d.file { loc += file }
        if let line = d.line { loc += ":\(line)" }
        if let column = d.column { loc += ":\(column)" }
        return (loc.isEmpty ? "" : loc + ": ") + "\(d.severity.rawValue): \(d.message)"
    }
}

let argv = CommandLine.arguments
let command = argv.count > 1 ? argv[1] : "help"
let rest = argv.dropFirst(2)

do {
    let args = try Arguments(rest, valued: ["format", "out", "on-change", "rate", "scd", "project", "from", "agent", "renderer", "soundfont",
                                            "to", "show", "file", "restore", "timing", "role"])
    let status: Int32
    switch command {
    case "render": status = try await render(args)
    case "check": status = try await check(args)
    case "links": status = try links(args)
    case "doctor": status = try await doctor(args)
    case "watch": status = try await watch(args)
    case "cues": status = try await cues(args)
    case "timeline": status = try await timeline(args)
    case "handlers": status = try await handlers(args)
    case "lexicon": status = try lexiconCommand(args)
    case "history": status = try await historyCommand(args)
    case "completion": status = try completion(args)
    case "mockup": status = try await mockup(args)
    case "mix": status = try await mix(args)
    case "patch": status = try await patchCommand(args)
    case "rpc":
        guard let method = args.positional.first else { throw CLIError("rpc needs a method name") }
        let params = try args.positional.dropFirst().first.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? [:]
        print(try RPCClient.call(method, params).jsonString(pretty: true))
        status = 0
    case "mcp":
        let project = URL(fileURLWithPath: args.options["project"] ?? FileManager.default.currentDirectoryPath)
        // `--role graphics|patch`: the tools and files of one of the app's agents.
        await MCPServer(project: project, role: args.options["role"].flatMap(MCPServer.Role.init(rawValue:))).serveStdio()
        status = 0
    case "agents":
        let dir = URL(fileURLWithPath: args.positional.first ?? FileManager.default.currentDirectoryPath)
        var failed = false
        for change in AgentSetup.ensure(in: dir) {
            switch change.outcome {
            case .created: print("\(change.file): created")
            case .added: print("\(change.file): added the pondside server")
            case .present: print("\(change.file): already has a pondside server")
            case .skipped(let why): printErr("\(change.file): left alone (\(why))"); failed = true
            }
        }
        status = failed ? 1 : 0
    case "version", "--version": print("pondside 0.1.0 (M1)"); status = 0
    case "help", "--help", "-h": print(usage); status = 0
    default:
        printErr("unknown command '\(command)'\n\n\(usage)")
        status = 2
    }
    exit(status)
} catch {
    printErr("pondside: \(error)")
    exit(1)
}

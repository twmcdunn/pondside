import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon

/// The folder a project lives in (its project root) and what Pondside keeps
/// in it, the same for every project, whether it was made with New, opened
/// for the first time, or migrated:
///
///     <root>/<name>.ly                   the score (pondside.toml's [project] score, if set)
///     <root>/lexicon.ily                 the Lexicon entries the score uses (generated)
///     <root>/patch/<name>.scd            the SuperCollider patch
///     <root>/patch/dependencies/pondside.scd   its engine (generated)
///     <root>/patch/resources/            the patch's sounds (pondside.toml's [supercollider] resources, if set)
///     <root>/renders/                    mockup, cue times, mix
///     <root>/.mcp.json, opencode.json, .codex/config.toml    `pondside mcp` for agents started here
///
/// `ensure` only adds what is missing and rewrites generated files whose
/// content changed; it never touches the composer's own files.
public enum ProjectStructure {
    /// What a folder holds as its score.
    public enum RootScore: Equatable, Sendable {
        case score(URL)
        /// No `.ly` file at the top of the folder.
        case none
        /// Several candidates, none of them clearly the root.
        case ambiguous([URL])

        public static func == (lhs: RootScore, rhs: RootScore) -> Bool {
            func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
            switch (lhs, rhs) {
            case let (.score(a), .score(b)): return canonical(a) == canonical(b)
            case let (.ambiguous(a), .ambiguous(b)): return a.map(canonical) == b.map(canonical)
            case (.none, .none): return true
            default: return false
            }
        }
    }

    /// Existing projects may predate pondside.toml; recognize their layout too.
    public static func isProjectRoot(_ folder: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent(ProjectConfig.fileName).path) { return true }
        return ["patch", "renders"].allSatisfy { name in
            var directory: ObjCBool = false
            return fm.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &directory) && directory.boolValue
        }
    }

    /// Adopt an existing score without replacing any of its music.
    public static func adopt(score: URL) throws {
        let folder = score.deletingLastPathComponent()
        let config = folder.appendingPathComponent(ProjectConfig.fileName)
        let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        try Data(settingScore(score.lastPathComponent, in: text).utf8).write(to: config, options: .atomic)
        _ = ensure(score: score)
    }

    /// The score a project root opens: pondside.toml's `[project] score`;
    /// else its only `.ly` file; else, of the `.ly` files no other one
    /// `\include`s, the only one, or the one named after the folder or
    /// `score.ly`.
    public static func rootScore(in folder: URL) -> RootScore {
        let fm = FileManager.default
        if let data = fm.contents(atPath: folder.appendingPathComponent(ProjectConfig.fileName).path),
           let configured = (try? ProjectConfig(toml: String(decoding: data, as: UTF8.self), root: folder))?.score,
           fm.fileExists(atPath: configured.path) {
            return .score(configured)
        }
        let scores = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ly" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if scores.isEmpty { return .none }
        if scores.count == 1 { return .score(scores[0]) }
        let texts = scores.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }
        let roots = scores.filter { s in
            !texts.contains { $0.contains("\\include \"\(s.lastPathComponent)\"") }
        }
        if roots.count == 1 { return .score(roots[0]) }
        let pool = roots.isEmpty ? scores : roots
        for name in [folder.lastPathComponent + ".ly", "score.ly"] {
            if let s = pool.first(where: { $0.lastPathComponent == name }) { return .score(s) }
        }
        return .ambiguous(pool)
    }

    /// A new score: `\version`, the Lexicon include, a title and a bar.
    public static func template(title: String) -> String {
        let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let text = """
        \\version "2.26.0"
        \\include "lexicon.ily"

        \\header {
          title = "\(escapedTitle)"
        }

        \\relative c' {
          \\time 4/4
          c4 d e f | g1 \\bar "|."
        }

        """
        let files = [StructuralEditing.File(id: "score.ly", tree: SyntaxTree(text))]
        // This built-in, complete musical stream is validated by the same
        // portable migration as imported scores before any file is written.
        let changes = try! StructuralEditing.migrate(files, root: "score.ly", sharedBreaks: true)
        return changes.flatMap(\.edits).apply(to: text)
    }

    /// Makes `folder` a new project root holding `<folder name>.ly` (the
    /// folder is created if needed) and its structure. Returns the score.
    public static func create(at folder: URL) throws -> URL {
        let name = folder.lastPathComponent
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let score = folder.appendingPathComponent(name + ".ly")
        if !FileManager.default.fileExists(atPath: score.path) {
            try Data(template(title: name).utf8).write(to: score, options: .atomic)
        }
        ensure(score: score)
        return score
    }

    /// One thing `ensure` did or could not do, relative to the project root.
    public struct Change: Equatable, Sendable {
        public var path: String
        public var error: String?
    }

    /// Adds what the project around `score` is missing (see the type's
    /// doc). Safe to run on every open.
    @discardableResult
    public static func ensure(score: URL) -> [Change] {
        let fm = FileManager.default
        let root = score.deletingLastPathComponent()
        let config = try? ProjectConfig.find(from: score)
        let name = score.deletingPathExtension().lastPathComponent
        var changes: [Change] = []
        func attempt(_ path: String, _ body: () throws -> Bool) {
            do { if try body() { changes.append(Change(path: path)) } }
            catch { changes.append(Change(path: path, error: error.localizedDescription)) }
        }

        for change in AgentSetup.ensure(in: root) {
            switch change.outcome {
            case .created, .added: changes.append(Change(path: change.file))
            case .present: break
            case .skipped(let why): changes.append(Change(path: change.file, error: why))
            }
        }

        let renders = root.appendingPathComponent(HandlerSync.Layout.renders, isDirectory: true)
        attempt(HandlerSync.Layout.renders + "/") {
            guard !fm.fileExists(atPath: renders.path) else { return false }
            try fm.createDirectory(at: renders, withIntermediateDirectories: true)
            return true
        }

        // The patch as the SuperCollider pane would start it; a patch the
        // composer wrote elsewhere is still offered for migration (an
        // untouched starter counts as no patch).
        let patch = PatchMigration.patchURL(score: score, configured: config?.handlers)
        attempt(relative(patch, to: root)) {
            guard !fm.fileExists(atPath: patch.path) else { return false }
            try fm.createDirectory(at: patch.deletingLastPathComponent(), withIntermediateDirectories: true)
            let sheet = CueSheet(log: TimingLog(rows: []), score: score.lastPathComponent)
            try Data(HandlerSync.patchStarter(sheet, name: name).utf8).write(to: patch, options: .atomic)
            return true
        }
        attempt(relative(PatchMigration.engineURL(patch: patch), to: root)) {
            try PatchMigration.ensureEngine(patch: patch, name: name)
        }

        // Sounds the patch loads ("resources/x.wav".resolveRelative); empty to start.
        let resources = config?.resources ?? patch.deletingLastPathComponent().appendingPathComponent("resources", isDirectory: true)
        attempt(relative(resources, to: root) + "/") {
            guard !fm.fileExists(atPath: resources.path) else { return false }
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            return true
        }

        // Generated, so it is rebuilt here: a score copied without it, or a
        // kit path from an older install, still engraves.
        let include = root.appendingPathComponent("lexicon.ily")
        attempt("lexicon.ily") {
            let graph = SourceGraph.load(root: score)
            let used = Set(graph.files.flatMap { LexiconUse.find(in: $0.text).map(\.id) })
            let lexicon = Lexicon.load(Lexicon.standardScopes(project: root))
            let text = lexicon.includeFile(for: used)
            if (try? String(contentsOf: include, encoding: .utf8)) == text { return false }
            try Data(text.utf8).write(to: include, options: .atomic)
            return true
        }
        return changes
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let r = root.path, p = url.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }

    /// `text` (a pondside.toml, possibly empty) with `[project] score` set.
    public static func settingScore(_ file: String, in text: String) -> String {
        ProjectConfig.setting(section: "project", key: "score", value: file, in: text)
    }
}

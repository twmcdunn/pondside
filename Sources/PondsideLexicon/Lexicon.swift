import Foundation

/// The Lexicon: entries from three scopes, later scopes overriding earlier
/// ones by id (core → user → project), read in three tiers of detail so an
/// agent can browse a hundred entries for about two thousand tokens.
public struct Lexicon: Sendable {
    /// `draft`: entries an agent proposed, in the project's `Lexicon/drafts/`,
    /// usable in the score but not yet accepted (DESIGN.md §7).
    public enum Scope: String, CaseIterable, Codable, Sendable { case core, user, project, draft }

    public struct Loaded: Sendable, Hashable {
        public var entry: LexiconEntry
        public var scope: Scope
        public var directory: URL
    }

    public private(set) var entries: [String: Loaded] = [:]
    /// Entries hidden by a later scope's entry of the same id.
    public private(set) var shadowed: [Loaded] = []
    /// Entries that failed validation (they are left out, never half-used).
    public private(set) var problems: [LexiconEntry.Problem] = []

    public init() {}

    /// Loads `<root>/entries/*/entry.toml` for each scope, in order.
    public static func load(_ scopes: [(Scope, URL)]) -> Lexicon {
        var lex = Lexicon()
        let fm = FileManager.default
        for (scope, root) in scopes {
            let entriesDir = root.appendingPathComponent("entries")
            guard let names = try? fm.contentsOfDirectory(atPath: entriesDir.path) else { continue }
            for name in names.sorted() {
                let dir = entriesDir.appendingPathComponent(name)
                guard let data = fm.contents(atPath: dir.appendingPathComponent("entry.toml").path) else { continue }
                do {
                    let entry = try LexiconEntry(toml: String(decoding: data, as: UTF8.self), directoryName: name)
                    if !fm.fileExists(atPath: dir.appendingPathComponent(entry.implFile).path) {
                        lex.problems.append(.init(entry: entry.id, message: "\(entry.implFile) is missing"))
                        continue
                    }
                    if let old = lex.entries[entry.id] { lex.shadowed.append(old) }
                    lex.entries[entry.id] = Loaded(entry: entry, scope: scope, directory: dir)
                } catch let e as LexiconProblems {
                    lex.problems += e.problems
                } catch {
                    lex.problems.append(.init(entry: name, message: "\(error)"))
                }
            }
        }
        return lex
    }

    /// The standard scopes: the bundled core, the user's library, and the
    /// project's `Lexicon/` folder beside the score (if any).
    public static func standardScopes(project: URL?) -> [(Scope, URL)] {
        var out: [(Scope, URL)] = []
        if let core = Bundle.module.url(forResource: "Core", withExtension: nil) {
            out.append((.core, core.appendingPathComponent("Lexicon")))
        }
        out.append((.user, userDirectory))
        if let project {
            out.append((.project, project.appendingPathComponent("Lexicon")))
            out.append((.draft, draftsDirectory(project: project)))
        }
        return out
    }

    /// `Lexicon/drafts` beside the score: proposed entries live in its `entries/`.
    public static func draftsDirectory(project: URL) -> URL {
        project.appendingPathComponent("Lexicon/drafts")
    }

    /// The bundled core: its Lexicon, the graphics kit and the skills.
    public static var coreDirectory: URL? { Bundle.module.url(forResource: "Core", withExtension: nil) }

    /// The graphics kit every graphic entry draws with (DESIGN.md §7).
    public static var graphicsKit: URL? {
        coreDirectory?.appendingPathComponent("Lexicon/kit/pondside-graphics.ily")
    }

    /// Pitch collections, `\collection { … }` (DESIGN.md §13): every
    /// generated `lexicon.ily` includes it.
    public static var collectionsKit: URL? {
        coreDirectory?.appendingPathComponent("Lexicon/kit/pondside-collections.ily")
    }

    public static var userDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["PONDSIDE_LEXICON"] { return URL(fileURLWithPath: custom) }
        #if os(macOS)
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pondside/Lexicon")
        #else
        let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("pondside/Lexicon")
        #endif
    }

    public var ids: [String] { entries.keys.sorted() }

    // MARK: Tiers

    struct IndexLine: Encodable {
        var id: String
        var gloss: String
        var kind: String
        var tags: [String]
        var params: [String]
        var sound: Bool
    }

    /// Tier 0: `index.json`, one line per entry sorted by id, so it diffs
    /// cleanly and costs about twenty tokens an entry.
    public func indexJSON() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = ids.compactMap { id -> String? in
            guard let l = entries[id] else { return nil }
            let line = IndexLine(id: id, gloss: l.entry.gloss, kind: l.entry.kind.rawValue, tags: l.entry.tags,
                                 params: l.entry.params.map(\.name), sound: l.entry.sound != nil)
            return (try? e.encode(line)).map { String(decoding: $0, as: UTF8.self) }
        }
        return lines.isEmpty ? "[]\n" : "[\n" + lines.joined(separator: ",\n") + "\n]\n"
    }

    /// Tier 1: the whole entry.toml and the README.
    public func tier1(_ id: String) -> String? {
        guard let l = entries[id] else { return nil }
        let toml = (try? String(contentsOf: l.directory.appendingPathComponent("entry.toml"), encoding: .utf8)) ?? ""
        let readme = (try? String(contentsOf: l.directory.appendingPathComponent(l.entry.readmeFile), encoding: .utf8)) ?? ""
        return "# \(id) \(l.entry.version) (\(l.scope.rawValue))\n\n```toml\n\(toml)```\n\n\(readme)"
    }

    /// Entries matching `query`, best first: words in the id and tags count
    /// most, then the gloss and param names. Tier 0 lines, so cheap to read.
    public func search(_ query: String, limit: Int = 8) -> [String] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let scored = ids.compactMap { id -> (Int, String)? in
            guard let l = entries[id] else { return nil }
            let strong = ([id] + l.entry.tags).joined(separator: " ").lowercased()
            let weak = ([l.entry.gloss] + l.entry.params.map(\.name)).joined(separator: " ").lowercased()
            let score = words.reduce(0) { $0 + (strong.contains($1) ? 3 : 0) + (weak.contains($1) ? 1 : 0) }
            guard words.isEmpty || score > 0 else { return nil }
            let line = IndexLine(id: id, gloss: l.entry.gloss, kind: l.entry.kind.rawValue, tags: l.entry.tags,
                                 params: l.entry.params.map(\.name), sound: l.entry.sound != nil)
            return (try? e.encode(line)).map { (score, String(decoding: $0, as: UTF8.self)) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// Writes a proposed entry to the project's drafts, after validating its
    /// entry.toml. Returns the folder; throws every problem at once.
    @discardableResult
    public static func propose(id: String, toml: String, impl: String, readme: String, project: URL) throws -> URL {
        let entry = try LexiconEntry(toml: toml, directoryName: id)
        guard entry.id == id else {
            throw LexiconProblems(problems: [.init(entry: id, message: "entry.toml says id = \"\(entry.id)\"")])
        }
        let dir = draftsDirectory(project: project).appendingPathComponent("entries/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try toml.write(to: dir.appendingPathComponent("entry.toml"), atomically: true, encoding: .utf8)
        try impl.write(to: dir.appendingPathComponent(entry.implFile), atomically: true, encoding: .utf8)
        try readme.write(to: dir.appendingPathComponent(entry.readmeFile), atomically: true, encoding: .utf8)
        return dir
    }

    /// Accepts a draft: moves it into the project's Lexicon, or the user's.
    /// The person decides this; agents only propose.
    @discardableResult
    public static func promote(id: String, project: URL, to scope: Scope = .project) throws -> URL {
        let from = draftsDirectory(project: project).appendingPathComponent("entries/\(id)")
        guard FileManager.default.fileExists(atPath: from.path) else { throw LexiconProblems(problems: [.init(entry: id, message: "no draft named \(id)")]) }
        let root = scope == .user ? userDirectory : project.appendingPathComponent("Lexicon")
        let to = root.appendingPathComponent("entries/\(id)")
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
        try FileManager.default.moveItem(at: from, to: to)
        return to
    }

    /// Rejects a draft: deletes it.
    public static func discard(id: String, project: URL) throws {
        try FileManager.default.removeItem(at: draftsDirectory(project: project).appendingPathComponent("entries/\(id)"))
    }

    /// Tier 2: the implementation, for adapting it.
    public func tier2(_ id: String) -> String? {
        guard let l = entries[id] else { return nil }
        return try? String(contentsOf: l.directory.appendingPathComponent(l.entry.implFile), encoding: .utf8)
    }

    // MARK: Engraving

    /// The settings file that makes `\lexicon "id" #'(…) music` work for
    /// `ids`: the dispatcher, each entry's defaults, its implementation, and
    /// a cue for entries that carry a sound.
    public func includeFile(for ids: Set<String>) -> String {
        var out = """
        % Generated by Pondside: the Lexicon entries this score uses.
        #(define pondside-lexicon-impls (make-hash-table))
        #(define pondside-lexicon-defaults (make-hash-table))
        #(define pondside-lexicon-cues (make-hash-table))
        #(define (pondside-lexicon-register! id proc) (hash-set! pondside-lexicon-impls id proc))

        """
        // Everything is written in, not included from the app or the user's
        // library: the project engraves without Pondside (DESIGN.md §0).
        // Graphic entries draw with the kit; it comes first, once.
        let graphics = ids.filter { entries[$0]?.entry.kind == .graphic }
        if !graphics.isEmpty, let kit = Self.graphicsKit {
            out += Self.inlined(kit, label: kit.lastPathComponent)
        }
        // `\collection`, wherever the score uses it.
        if let kit = Self.collectionsKit {
            out += Self.inlined(kit, label: kit.lastPathComponent)
        }
        for id in ids.sorted() {
            guard let l = entries[id] else { continue }
            let defaults = l.entry.params.compactMap { p -> String? in
                p.defaultValue.map { "(\(p.name) . \(Self.scheme($0)))" }
            }
            out += "#(hash-set! pondside-lexicon-defaults \(Self.schemeString(id)) '(\(defaults.joined(separator: " "))))\n"
            if l.entry.kind == .graphic {
                out += "#(hash-set! pondside-graphics-defaults \(Self.schemeString(id)) '(\(defaults.joined(separator: " "))))\n"
            }
            if let cue = l.entry.sound?.cue {
                out += "#(hash-set! pondside-lexicon-cues \(Self.schemeString(id)) \(Self.schemeString(cue)))\n"
            }
            out += Self.inlined(l.directory.appendingPathComponent(l.entry.implFile), label: "\(id) \(l.entry.version)")
        }
        out += """

        lexicon =
        #(define-music-function (id params music) (string? list? ly:music?)
           (let ((proc (hash-ref pondside-lexicon-impls id #f))
                 (defaults (hash-ref pondside-lexicon-defaults id '()))
                 (cue (hash-ref pondside-lexicon-cues id #f)))
             (if (not proc)
                 (begin (ly:input-warning (*location*) "Lexicon has no entry ~a" id) music)
                 (let* ((merged (append params (filter (lambda (d) (not (assq (car d) params))) defaults)))
                        (result (proc merged music)))
                   (if cue
                       (let ((ev (make-music 'TextScriptEvent 'direction UP 'text "" 'cue-label cue
                                             ; for cues.json: the entry, its length, its params as written
                                             'pondside-lexicon (list id (ly:moment-main (ly:music-length music))
                                                                     (format #f "~s" merged)))))
                         (ly:music-set-property! ev 'tweaks (list (cons 'stencil #f)))
                         (make-sequential-music (list (make-music 'EventChord 'elements (list ev)) result)))
                       result)))))

        """
        return out
    }

    /// A file's text, between banner lines naming it, for lexicon.ily.
    static func inlined(_ url: URL, label: String) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "% (missing)\n"
        return "\n%% ---- \(label)\n" + text + (text.hasSuffix("\n") ? "" : "\n") + "%% ---- end \(label)\n\n"
    }

    public static func scheme(_ v: TOMLValue) -> String {
        switch v {
        case .string(let s): return schemeString(s)
        case .integer(let i): return String(i)
        case .float(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) + ".0" : String(d)
        case .bool(let b): return b ? "#t" : "#f"
        case .array(let a): return "(" + a.map(scheme).joined(separator: " ") + ")"
        case .table: return "'()"
        }
    }

    static func schemeString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension Lexicon {
    /// Evaluates a use's `[sound]` params for cues.json: the entry's defaults
    /// under the params as written, with the cue's real timing.
    public func soundParams(entry id: String, params: String, beatDur: Double, spanDur: Double, tempo: Double) -> [String: Double]? {
        guard let entry = entries[id]?.entry, entry.sound != nil else { return nil }
        var values: [String: TOMLValue] = [:]
        for p in entry.params { if let d = p.defaultValue { values[p.name] = d } }
        for (k, v) in LexiconUse.params(fromAlist: params) { values[k] = v }
        guard let evaluated = try? entry.soundParams(values, beatDur: beatDur, spanDur: spanDur, tempo: tempo) else { return nil }
        return Dictionary(evaluated, uniquingKeysWith: { a, _ in a })
    }
}

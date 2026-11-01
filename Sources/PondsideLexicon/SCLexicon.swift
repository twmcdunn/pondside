import Foundation

/// The SuperCollider Lexicon: effects and pattern parts a patch can use, as
/// the graphic Lexicon is for the score (docs/SUPERCOLLIDER.md, "The
/// SuperCollider Lexicon"). Each entry is a folder `entries/<id>/` with
/// `entry.toml` (id, gloss, kind, tags, the SuperCollider name, params with
/// defaults and docs, `requires`, `usage`), `impl.scd` and `README.md`.
/// Core entries ship in `Core/SCLexicon`; a project adds its own in
/// `SCLexicon/entries/` beside the score.
///
/// A patch uses entries through `patch/dependencies/sc-lexicon.scd`, which
/// Pondside writes (`includeFile`): the kit, then every entry used and what
/// it requires, then `~lxBuildFx.value`.
public struct SCLexicon: Sendable {
    public struct Entry: Sendable, Hashable {
        public struct Param: Sendable, Hashable {
            public var name: String
            public var defaultValue: String
            public var doc: String
        }

        public var id: String
        /// `effect` (two SynthDefs, \lx_<name> and \lx_<name>_mono),
        /// `synth` (a SynthDef) or `pattern` (a function, ~lx[\name]).
        public var kind: String
        /// The name in SuperCollider: `\lx_reverb`, `~lx[\cloud]`.
        public var name: String
        public var gloss: String
        public var tags: [String]
        public var params: [Param]
        public var requires: [String]
        public var usage: String
        public var directory: URL
        public var scope: String

        /// How code calls it.
        public var reference: String {
            switch kind {
            case "effect": return "\\lx_\(name) (insert, Pfxb) · \\lx_\(name)_mono (on a mono bus such as ~live)"
            case "synth": return "\\lx_\(name)"
            default: return "~lx[\\\(name)]"
            }
        }

        public var impl: String { (try? String(contentsOf: directory.appendingPathComponent("impl.scd"), encoding: .utf8)) ?? "" }
        public var readme: String { (try? String(contentsOf: directory.appendingPathComponent("README.md"), encoding: .utf8)) ?? "" }

        /// `reverb (effect): Reverb on a stereo signal · \lx_reverb … · params mix room damp`
        public var indexLine: String {
            "\(id) (\(kind)): \(gloss) · \(reference)" + (params.isEmpty ? "" : " · params " + params.map(\.name).joined(separator: " "))
        }
    }

    public private(set) var entries: [String: Entry] = [:]
    public var ids: [String] { entries.keys.sorted() }

    public init() {}

    public static var coreDirectory: URL? { Lexicon.coreDirectory?.appendingPathComponent("SCLexicon") }
    public static var kitURL: URL? { coreDirectory?.appendingPathComponent("kit/sc-lexicon-kit.scd") }

    /// Core entries, then the project's (`SCLexicon/` beside the score),
    /// which replace core ones of the same id.
    public static func load(project: URL?) -> SCLexicon {
        var lex = SCLexicon()
        var roots: [(String, URL)] = []
        if let core = coreDirectory { roots.append(("core", core)) }
        if let project { roots.append(("project", project.appendingPathComponent("SCLexicon"))) }
        for (scope, root) in roots {
            let dir = root.appendingPathComponent("entries")
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
                let folder = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: folder.appendingPathComponent("entry.toml"), encoding: .utf8),
                      let entry = try? parse(text, directory: folder, scope: scope), entry.id == name else { continue }
                lex.entries[entry.id] = entry
            }
        }
        return lex
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    static func parse(_ text: String, directory: URL, scope: String) throws -> Entry {
        let t = try TOML.parse(text)
        guard let id = t["id"]?.string, let kind = t["kind"]?.string, ["effect", "synth", "pattern"].contains(kind),
              let name = t["sc"]?["name"]?.string else {
            throw Failure(description: "\(directory.lastPathComponent)/entry.toml needs id, kind (effect, synth or pattern) and [sc] name")
        }
        let paramTable = t["params"]?.table ?? [:]
        let order = text.components(separatedBy: "\n").compactMap { l -> String? in
            guard l.hasPrefix("[params."), l.hasSuffix("]") else { return nil }
            return String(l.dropFirst("[params.".count).dropLast())
        }
        let params = order.compactMap { k -> Entry.Param? in
            guard let p = paramTable[k] else { return nil }
            let d: String
            switch p["default"] {
            case .integer(let i)?: d = String(i)
            case .float(let f)?: d = String(f)
            case .string(let s)?: d = s
            case .bool(let b)?: d = String(b)
            default: d = ""
            }
            return Entry.Param(name: k, defaultValue: d, doc: p["doc"]?.string ?? "")
        }
        return Entry(id: id, kind: kind, name: name, gloss: t["gloss"]?.string ?? "",
                     tags: t["tags"]?.array?.compactMap(\.string) ?? [],
                     params: params, requires: t["sc"]?["requires"]?.array?.compactMap(\.string) ?? [],
                     usage: t["sc"]?["usage"]?.string ?? "", directory: directory, scope: scope)
    }

    /// Entries for a description, best first: one index line each.
    public func search(_ query: String, limit: Int = 8) -> [String] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        let scored = ids.compactMap { id -> (Int, String)? in
            guard let e = entries[id] else { return nil }
            let strong = ([id, e.name, e.kind] + e.tags).joined(separator: " ").lowercased()
            let weak = (e.gloss + " " + e.params.map { $0.name + " " + $0.doc }.joined(separator: " ")).lowercased()
            let score = words.reduce(0) { $0 + (strong.contains($1) ? 3 : 0) + (weak.contains($1) ? 1 : 0) }
            return score > 0 || words.isEmpty ? (score, e.indexLine) : nil
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// Everything about one entry: what it is, its params, how to call it,
    /// its README and its code (they are short).
    public func describe(_ id: String) -> String? {
        guard let e = entries[id] else { return nil }
        var out = "# \(e.id) (\(e.kind), \(e.scope))\n\n\(e.gloss)\n\nIn SuperCollider: \(e.reference)\n"
        if !e.params.isEmpty {
            out += "\nParams:\n" + e.params.map { "- \($0.name) = \($0.defaultValue): \($0.doc)" }.joined(separator: "\n") + "\n"
        }
        if !e.requires.isEmpty { out += "\nRequires: \(e.requires.joined(separator: ", ")) (sc_lexicon_add adds them)\n" }
        if !e.usage.isEmpty { out += "\nUsage:\n```supercollider\n\(e.usage)\n```\n" }
        out += "\n\(e.readme)\n\nimpl.scd:\n```supercollider\n\(e.impl)\n```\n"
        return out
    }

    /// `ids` and what they require, dependencies first.
    public func closure(_ ids: [String]) -> [String] {
        var out: [String] = []
        func visit(_ id: String, _ path: Set<String>) {
            guard !out.contains(id), !path.contains(id), let e = entries[id] else { return }
            for r in e.requires { visit(r, path.union([id])) }
            out.append(id)
        }
        for id in ids { visit(id, []) }
        return out
    }

    /// `sc-lexicon.scd` for `ids`.
    public func includeFile(for ids: [String]) -> String {
        let all = closure(ids)
        let kit = SCLexicon.kitURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        var out = """
        // Pondside's SuperCollider Lexicon entries this patch uses. Pondside writes this file \
        (sc_lexicon_add, pondside sc-lexicon): don't edit it; copy an entry into the patch to change it.
        \(SCLexiconIncludeMarker.marker) \(all.joined(separator: " "))

        \(kit)

        """
        for id in all {
            guard let e = entries[id] else { continue }
            out += "// ---- \(id): \(e.gloss)\n" + e.impl.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        out += "~lxBuildFx.value;\n"
        return out
    }
}

/// The include's marker, shared with PondsideTiming's reader of it
/// (`SCLexiconInclude`), which this module doesn't import.
enum SCLexiconIncludeMarker {
    static let marker = "// @pondside sc-lexicon"
}

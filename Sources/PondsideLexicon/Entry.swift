import Foundation
import PondsideCore

/// One Lexicon entry: a notational idea with typed parameters, a LilyPond
/// implementation and, optionally, the sound it stands for (DESIGN.md §3).
public struct LexiconEntry: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case symbol, texture, pattern, gesture, layout, system, graphic }
    public enum Attachment: String, CaseIterable, Sendable { case point, span, staff, system }

    public struct Param: Hashable, Sendable {
        public enum ParamType: String, CaseIterable, Sendable { case float, int, bool, string, `enum`, duration, pitch, markup, envelope, list }
        public var name: String
        public var type: ParamType
        public var defaultValue: TOMLValue?
        public var min: Double?
        public var max: Double?
        public var values: [String]
        public var unit: String?
        public var doc: String?
    }

    public struct Sound: Hashable, Sendable {
        public var synthdef: String?
        public var cue: String
        public var params: [(name: String, expression: Expression)]
        public var emit: String

        public static func == (a: Sound, b: Sound) -> Bool {
            a.synthdef == b.synthdef && a.cue == b.cue && a.emit == b.emit
                && a.params.map(\.name) == b.params.map(\.name) && a.params.map(\.expression) == b.params.map(\.expression)
        }

        public func hash(into h: inout Hasher) {
            h.combine(cue)
            h.combine(synthdef)
        }
    }

    public var id: String
    public var version: String
    public var gloss: String
    public var tags: [String]
    public var kind: Kind
    public var lilypond: String?
    public var attaches: Attachment
    /// The example invocation from `[entry] command`, for previews.
    public var command: String?
    public var musicArg: Bool
    /// In file order.
    public var params: [Param]
    public var sound: Sound?
    public var implFile: String
    public var readmeFile: String
    public var previewFile: String?

    /// Names a sound expression may read besides the params.
    public static let timingNames: Set<String> = ["beatDur", "spanDur", "tempo"]

    public struct Problem: Error, Hashable, Sendable, CustomStringConvertible {
        public var entry: String
        public var message: String
        public var description: String { "\(entry): \(message)" }
    }

    /// Reads and validates an entry.toml. Every problem is reported, not
    /// just the first, so an agent fixing an entry fixes it in one pass.
    public init(toml text: String, directoryName: String? = nil) throws {
        let doc: [String: TOMLValue]
        do { doc = try TOML.parse(text) } catch {
            throw LexiconProblems(problems: [Problem(entry: directoryName ?? "?", message: "\(error)")])
        }
        var problems: [String] = []
        func need(_ key: String) -> String {
            guard let v = doc[key]?.string else { problems.append("missing \(key)"); return "" }
            return v
        }
        id = need("id")
        version = need("version")
        gloss = need("gloss")
        tags = doc["tags"]?.array?.compactMap(\.string) ?? []
        lilypond = doc["lilypond"]?.string
        let kindText = need("kind")
        kind = Kind(rawValue: kindText) ?? .symbol
        if !kindText.isEmpty, Kind(rawValue: kindText) == nil {
            problems.append("kind must be one of \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        if doc["schema"]?.int != 1 { problems.append("schema must be 1") }
        if !id.isEmpty, !Self.isKebab(id) { problems.append("id must be kebab-case (a-z, 0-9, -)") }
        if let directoryName, !id.isEmpty, directoryName != id { problems.append("id \(id) differs from its folder \(directoryName)") }
        if gloss.count > 80 { problems.append("gloss is \(gloss.count) characters; tier 0 allows 80") }
        if !version.isEmpty, version.split(separator: ".").count != 3 || version.split(separator: ".").contains(where: { Int($0) == nil }) {
            problems.append("version must be semver (1.2.0)")
        }

        let entry = doc["entry"]?.table ?? [:]
        let attachText = entry["attaches"]?.string ?? "point"
        attaches = Attachment(rawValue: attachText) ?? .point
        if Attachment(rawValue: attachText) == nil { problems.append("entry.attaches must be point, span, staff or system") }
        musicArg = entry["music-arg"]?.bool ?? (attaches == .span)
        command = entry["command"]?.string

        // Params keep the order they appear in the file (TOML tables don't).
        let order = Self.tableOrder(text, under: "params")
        let table = doc["params"]?.table ?? [:]
        var params: [Param] = []
        for name in order + table.keys.filter({ !order.contains($0) }).sorted() {
            guard let p = table[name]?.table else { continue }
            guard let t = p["type"]?.string.flatMap(Param.ParamType.init(rawValue:)) else {
                problems.append("params.\(name).type must be one of \(Param.ParamType.allCases.map(\.rawValue).joined(separator: ", "))")
                continue
            }
            let param = Param(name: name, type: t, defaultValue: p["default"], min: p["min"]?.number, max: p["max"]?.number,
                              values: p["values"]?.array?.compactMap(\.string) ?? [], unit: p["unit"]?.string, doc: p["doc"]?.string)
            if let d = param.defaultValue, let why = param.reject(d) { problems.append("params.\(name).default: \(why)") }
            if t == .enum && param.values.isEmpty { problems.append("params.\(name) is an enum without values") }
            params.append(param)
        }
        self.params = params

        if let s = doc["sound"]?.table {
            var bound: [(name: String, expression: Expression)] = []
            let known = Set(params.map(\.name)).union(Self.timingNames)
            let order = Self.inlineOrder(text, key: "params", inTable: "sound")
            let table = s["params"]?.table ?? [:]
            for name in order + table.keys.filter({ !order.contains($0) }).sorted() {
                guard let src = table[name]?.string else { problems.append("sound.params.\(name) must be a string expression"); continue }
                do {
                    let e = try Expression(parsing: src)
                    for unknown in e.names.subtracting(known).sorted() {
                        problems.append("sound.params.\(name) reads \(unknown), which is neither a param nor beatDur/spanDur/tempo")
                    }
                    bound.append((name, e))
                } catch {
                    problems.append("sound.params.\(name): \(error)")
                }
            }
            let cue = s["cue"]?.string ?? ""
            if cue.isEmpty { problems.append("sound.cue is required: it names the cue the entry emits") }
            sound = Sound(synthdef: s["synthdef"]?.string, cue: cue, params: bound, emit: s["emit"]?.string ?? "onset")
        } else {
            sound = nil
        }

        let files = doc["files"]?.table ?? [:]
        implFile = files["impl"]?.string ?? "impl.ily"
        readmeFile = files["readme"]?.string ?? "README.md"
        previewFile = doc["preview"]?["file"]?.string

        if !problems.isEmpty {
            let name = id.isEmpty ? (directoryName ?? "?") : id
            throw LexiconProblems(problems: problems.map { Problem(entry: name, message: $0) })
        }
    }

    static func isKebab(_ s: String) -> Bool {
        guard let f = s.first, f.isLetter, f.isLowercase, s.last != "-" else { return false }
        return s.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" } && !s.contains("--")
    }

    /// The names of `[under.NAME]` tables in file order.
    static func tableOrder(_ text: String, under: String) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[\(under)."), let close = line.firstIndex(of: "]") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: under.count + 2)..<close])
            if !name.contains("."), !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Keys of an inline table `key = { a = …, b = … }` inside `[inTable]`, in order.
    static func inlineOrder(_ text: String, key: String, inTable: String) -> [String] {
        var inside = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inside = line == "[\(inTable)]"; continue }
            guard inside, line.hasPrefix(key), let open = line.firstIndex(of: "{") else { continue }
            var names: [String] = []
            var depthQuote = false
            var token = ""
            var expectingKey = true
            for ch in line[line.index(after: open)...] {
                if ch == "\"" { depthQuote.toggle(); continue }
                if depthQuote { continue }
                if ch == "=" && expectingKey {
                    names.append(token.trimmingCharacters(in: .whitespaces))
                    token = ""
                    expectingKey = false
                } else if ch == "," {
                    expectingKey = true
                    token = ""
                } else if expectingKey {
                    token.append(ch)
                }
            }
            return names
        }
        return []
    }

    /// Tier 0: what an agent reads for every entry (~20 tokens).
    public var tier0: [String: Any] {
        ["id": id, "gloss": gloss, "tags": tags, "params": params.map(\.name), "kind": kind.rawValue]
    }

    /// The defaults merged with `given`; rejects unknown names and bad values.
    public func resolve(_ given: [String: TOMLValue]) throws -> [String: TOMLValue] {
        var out: [String: TOMLValue] = [:]
        var problems: [String] = []
        for name in given.keys.sorted() where !params.contains(where: { $0.name == name }) {
            problems.append("\(id) has no param \(name) (it has \(params.map(\.name).joined(separator: ", ")))")
        }
        for p in params {
            if let v = given[p.name] {
                if let why = p.reject(v) { problems.append("\(p.name): \(why)") } else { out[p.name] = v }
            } else if let d = p.defaultValue {
                out[p.name] = d
            } else {
                problems.append("\(p.name) has no default and must be given")
            }
        }
        if !problems.isEmpty { throw LexiconProblems(problems: problems.map { Problem(entry: id, message: $0) }) }
        return out
    }

    /// The sound binding's values for one use, given its timing.
    public func soundParams(_ values: [String: TOMLValue], beatDur: Double, spanDur: Double, tempo: Double) throws -> [(String, Double)] {
        guard let sound else { return [] }
        var bindings = ["beatDur": beatDur, "spanDur": spanDur, "tempo": tempo]
        for (k, v) in values {
            switch v {
            case .integer(let i): bindings[k] = Double(i)
            case .float(let d): bindings[k] = d
            case .bool(let b): bindings[k] = b ? 1 : 0
            default: break
            }
        }
        return try sound.params.map { ($0.name, try $0.expression.evaluate(bindings)) }
    }
}

/// Everything wrong with an entry or a use of it, all at once.
public struct LexiconProblems: Error, Hashable, Sendable, CustomStringConvertible {
    public var problems: [LexiconEntry.Problem]
    public var description: String { problems.map(\.description).joined(separator: "\n") }
}

extension LexiconEntry.Param {
    /// The envelopes the graphics kit understands (`env-at`).
    static let envelopeKinds: Set<String> = ["constant", "linear", "swell", "pulse", "lfo", "points", "sum", "product", "smooth"]

    /// Why `v` is not a valid value, or nil.
    func reject(_ v: TOMLValue) -> String? {
        switch type {
        case .float, .int:
            guard let n = v.number else { return "expected a number" }
            if type == .int, v.int == nil { return "expected an integer" }
            if let min, n < min { return "\(n) is below the minimum \(min)" }
            if let max, n > max { return "\(n) is above the maximum \(max)" }
        case .bool:
            if v.bool == nil { return "expected true or false" }
        case .enum:
            guard let s = v.string else { return "expected one of \(values.joined(separator: ", "))" }
            if !values.contains(s) { return "\(s) is not one of \(values.joined(separator: ", "))" }
        case .string, .markup, .duration, .pitch:
            if v.string == nil { return "expected a string" }
        case .envelope:
            // 2, or (swell 3 0.5 4): see the graphics kit's env-at. A plain
            // number keeps to the param's range.
            if let n = v.number {
                if let min, n < min { return "\(n) is below the minimum \(min)" }
                if let max, n > max { return "\(n) is above the maximum \(max)" }
                return nil
            }
            guard let a = v.array, let head = a.first?.string else {
                return "expected a number or an envelope such as (swell 3 0.5 4)"
            }
            if !Self.envelopeKinds.contains(head) {
                return "\(head) is not an envelope; use one of \(Self.envelopeKinds.sorted().joined(separator: ", "))"
            }
        case .list:
            if v.array == nil { return "expected a list" }
        }
        return nil
    }
}

extension LexiconEntry {
    /// The entry as a row of the score's legend (front-matter.ily): its
    /// name, its gloss, and its own example drawn as notation.
    public var legendItem: FrontMatter.NewLegendItem {
        let words = id.split(separator: "-").map(String.init)
        let title = words.enumerated().map { $0 == 0 ? $1.prefix(1).uppercased() + $1.dropFirst() : $1 }.joined(separator: " ")
        let example = kind == .graphic ? FrontMatter.example(graphic: id) : FrontMatter.example(music: command ?? "c''1")
        return FrontMatter.NewLegendItem(id: id, title: title, text: gloss, example: example)
    }
}

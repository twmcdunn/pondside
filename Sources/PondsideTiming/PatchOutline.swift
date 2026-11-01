import Foundation
import PondsideCore

/// What a SuperCollider patch defines, each with where it is: its
/// SynthDefs, patterns, proxies, buses, buffers, functions, cue handlers
/// and live-only blocks, in the patch and the files it loads. Built from
/// the code every time, so it is never out of date: the patch agent reads
/// it first and opens only the lines it needs (docs/SUPERCOLLIDER.md,
/// "The patch agent").
public struct PatchOutline: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        /// `synthdef`, `pattern`, `pdef`, `ndef`, `bus`, `buffer`, `group`,
        /// `synth`, `function`, `routine`, `value`, `cue`, `live`.
        public var kind: String
        /// `\grain`, `~pb1`, `cue-12`, `block 3`.
        public var name: String
        /// Relative to the patch's folder.
        public var file: String
        public var fromLine: Int
        public var toLine: Int
        /// One line: a SynthDef's arguments, a cue's bar and time, the
        /// first line of anything else.
        public var summary: String
        /// A hash of the item's code, so a note about it can tell when the
        /// code has changed since.
        public var hash: String
        /// The environment variables (`~x`) and symbols (`\x`) its code
        /// uses: what a cue handler touches.
        public var references: [String]
        /// Further lines that assign the same name (`~verb = …` again).
        public var alsoAt: [Int] = []

        /// How the doc and the tools name it: `synthdef \grain`, `cue cue-12`.
        public var key: String { kind + " " + name }

        public var location: String { "\(file):\(fromLine)" + (toLine > fromLine ? "-\(toLine)" : "") }

        /// `synthdef \grain  score.scd:40-62  |out, freq, amp = 0.2|`
        public var line: String {
            key + "  " + location + (summary.isEmpty ? "" : "  " + summary)
                + (alsoAt.isEmpty ? "" : "  (also assigned at line " + alsoAt.map(String.init).joined(separator: ", ") + ")")
        }
    }

    public var items: [Item]
    /// The SuperCollider Lexicon entries the patch loads (sc-lexicon.scd).
    public var lexicon: [String] = []

    public init(items: [Item], lexicon: [String] = []) {
        self.items = items
        self.lexicon = lexicon
    }

    public func item(_ key: String) -> Item? {
        let k = key.trimmingCharacters(in: .whitespaces)
        return items.first { $0.key == k } ?? items.first { $0.name == k }
    }

    /// The items a set of references (`~verb`, `\grain`) names.
    public func resolve(_ references: [String]) -> [Item] {
        let wanted = Set(references)
        return items.filter { $0.kind != "cue" && $0.kind != "live" && wanted.contains($0.name) }
    }

    /// One line per item, in file order.
    public var text: String {
        var lines = items.map(\.line)
        if !lexicon.isEmpty { lines.append("lexicon  dependencies/sc-lexicon.scd  " + lexicon.joined(separator: " ")) }
        return lines.joined(separator: "\n")
    }

    // MARK: Building

    /// The outline of `patch` and the files it loads, Pondside's engine and
    /// Lexicon include left out (they are Pondside's, not the composer's).
    public static func build(patch: URL) -> PatchOutline {
        var items: [Item] = []
        var lexicon: [String] = []
        for url in [patch] + PatchMigration.dependencies(of: patch) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if url.lastPathComponent == SCLexiconInclude.fileName {
                lexicon = SCLexiconInclude.ids(in: text)
                continue
            }
            items += Self.items(in: text, file: PatchMigration.relative(url, to: patch))
        }
        return PatchOutline(items: items, lexicon: lexicon)
    }

    static let patternClasses: Set<String> = [
        "Pbind", "PbindProxy", "Pbindef", "Pmono", "PmonoArtic", "Ppar", "Ptpar", "Pgpar", "Pseq", "Prand", "Pxrand",
        "Pwrand", "Pshuf", "Pfx", "Pfxb", "Pbus", "Pchain", "Pbindf", "Pspawner", "Pspawn", "Pn", "Pseg", "Pwhite",
        "Pfin", "Pfindur", "Psync", "Plazy", "Pfunc", "Prout", "Pdef", "Pkey", "Pgeom", "Pseries", "Pstutter", "Pdup",
    ]

    /// The engine's own names (`~mode = \mockup;`), not the composer's items.
    static let engineNames: Set<String> = ["~mode", "~cue", "~live", "~triggerCue", "~stop", "~pondside"]

    /// The items of one file.
    public static func items(in text: String, file: String) -> [Item] {
        let u = Array(text.utf16)
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = [0]
        for (i, c) in u.enumerated() where c == 0x0A { starts.append(i + 1) }
        func line(_ offset: Int) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo + 1
        }
        func str(_ r: Range<Int>) -> String { String(decoding: u[r.clamped(to: 0..<u.count)], as: UTF16.self) }
        func code(_ from: Int, _ to: Int) -> String { lines[(from - 1)..<min(to, lines.count)].joined(separator: "\n") }

        var out: [Item] = []
        // Cue handlers, between Pondside's markers.
        var inCue = Set<Int>()
        for b in HandlerSync.blocks(lines) where !b.orphan {
            let header = lines[b.header]
            let detail = header.dropFirst(HandlerSync.headerPrefix.count).split(separator: "·", maxSplits: 1)
                .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let body = code(b.header + 1, b.end + 1)
            inCue.formUnion((b.header + 1)...(b.end + 1))
            out.append(Item(kind: "cue", name: b.id, file: file, fromLine: b.header + 1, toLine: b.end + 1,
                            summary: detail, hash: hash(body), references: references(in: SCLexer.tokenize(body), u: Array(body.utf16))))
        }
        // Live-only blocks.
        for r in SCRegion.topLevelBlocks(in: text) {
            let from = line(r.lowerBound), to = line(r.upperBound - 1)
            let body = code(from, to)
            if body.split(separator: "\n").dropFirst().first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .trimmingCharacters(in: .whitespaces).hasPrefix(HandlerSync.liveOnlyMarker) ?? false {
                out.append(Item(kind: "live", name: "block \(from)", file: file, fromLine: from, toLine: to,
                                summary: "live only (not in the mix)", hash: hash(body), references: []))
            }
        }

        let tokens = SCLexer.tokenize(u).filter { $0.kind != .whitespace && $0.kind != .comment }
        func t(_ i: Int) -> String { i < tokens.count && i >= 0 ? str(tokens[i].range) : "" }
        func kind(_ i: Int) -> SCTokenKind? { i < tokens.count && i >= 0 ? tokens[i].kind : nil }
        /// The index of the token closing the bracket opened at `i`.
        func close(_ i: Int) -> Int? {
            var depth = 0
            for k in i..<tokens.count {
                switch tokens[k].kind {
                case .openParen, .openBracket, .openBrace: depth += 1
                case .closeParen, .closeBracket, .closeBrace:
                    depth -= 1
                    if depth == 0 { return k }
                default: break
                }
            }
            return nil
        }
        /// The last token of the statement starting at `i`: the one before a
        /// `;` at depth 0, or before the enclosing block's close.
        func statementEnd(_ i: Int) -> Int {
            var depth = 0, k = i
            while k < tokens.count {
                switch tokens[k].kind {
                case .openParen, .openBracket, .openBrace: depth += 1
                case .closeParen, .closeBracket, .closeBrace:
                    if depth == 0 { return max(i, k - 1) }
                    depth -= 1
                case .punctuation where depth == 0 && t(k) == ";": return max(i, k - 1)
                default: break
                }
                k += 1
            }
            return tokens.count - 1
        }
        func startsStatement(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            let p = t(i - 1)
            return p == ";" || p == "(" || p == "{" || p == ")" && line(tokens[i - 1].range.lowerBound) < line(tokens[i].range.lowerBound)
                || kind(i - 1) == .punctuation && p == "|" && line(tokens[i - 1].range.lowerBound) < line(tokens[i].range.lowerBound)
        }
        func firstLine(_ from: Int) -> String {
            String(lines[from - 1].trimmingCharacters(in: .whitespaces).prefix(100))
        }
        func item(_ kind: String, _ name: String, _ a: Int, _ b: Int, summary: String? = nil) -> Item {
            let from = line(tokens[a].range.lowerBound), to = line(tokens[b].range.upperBound - 1)
            let body = code(from, to)
            let r = tokens[a].range.lowerBound..<tokens[b].range.upperBound
            return Item(kind: kind, name: name, file: file, fromLine: from, toLine: to, summary: summary ?? firstLine(from),
                        hash: hash(body), references: references(in: SCLexer.tokenize(str(r)), u: Array(str(r).utf16)))
        }

        var assigned: [String: Int] = [:]
        var i = 0
        while i < tokens.count {
            let word = t(i)
            let here = line(tokens[i].range.lowerBound)
            if inCue.contains(here) { i += 1; continue }
            // SynthDef(\name, { |args| … }).add
            if word == "SynthDef", t(i + 1) == "(", let c = close(i + 1), kind(i + 2) == .symbol || kind(i + 2) == .string {
                let name = "\\" + t(i + 2).trimmingCharacters(in: CharacterSet(charactersIn: "\\'\""))
                var args = ""
                if let brace = (i + 2...c).first(where: { t($0) == "{" }) {
                    if t(brace + 1) == "|", let bar = (brace + 2..<c).first(where: { t($0) == "|" }) {
                        args = "|" + str(tokens[brace + 2].range.lowerBound..<tokens[bar - 1].range.upperBound) + "|"
                    } else if t(brace + 1) == "arg", let semi = (brace + 2..<c).first(where: { t($0) == ";" }) {
                        args = "arg " + str(tokens[brace + 2].range.lowerBound..<tokens[semi - 1].range.upperBound) + ";"
                    }
                }
                out.append(item("synthdef", name, i, c, summary: args.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "  ", with: " ")))
                i = c + 1
                continue
            }
            // Pdef(\name, …), Ndef(\name, …), Tdef(\name, …): definitions only.
            if ["Pdef", "Ndef", "Tdef", "Pbindef"].contains(word), t(i + 1) == "(", kind(i + 2) == .symbol, t(i + 3) == ",",
               let c = close(i + 1) {
                let k = word == "Ndef" ? "ndef" : word == "Tdef" ? "routine" : "pdef"
                out.append(item(k, t(i + 2), i, c))
                i = c + 1
                continue
            }
            // ~name = …, at the start of a statement.
            if kind(i) == .environment, t(i + 1) == "=", startsStatement(i), !engineNames.contains(word) {
                let end = statementEnd(i + 2)
                let name = word
                if let first = assigned[name] {
                    if out[first].alsoAt.count < 5 { out[first].alsoAt.append(here) }
                    i = end + 1
                    continue
                }
                let rhs = t(i + 2)
                let k: String
                if rhs == "{" { k = "function" }
                else if patternClasses.contains(rhs) { k = "pattern" }
                else if rhs == "Bus" { k = "bus" }
                else if rhs == "Buffer" { k = "buffer" }
                else if rhs == "Group" || rhs == "ParGroup" { k = "group" }
                else if rhs == "Synth" { k = "synth" }
                else if rhs == "Routine" || rhs == "Task" || rhs == "Tdef" { k = "routine" }
                else if rhs == "Ndef" || rhs == "NodeProxy" { k = "ndef" }
                else { k = "value" }
                var summary = firstLine(line(tokens[i].range.lowerBound))
                if k == "function", t(i + 3) == "|", let bar = (i + 4...max(i + 4, end)).first(where: { t($0) == "|" }), bar > i + 4 {
                    summary = "|" + str(tokens[i + 4].range.lowerBound..<tokens[bar - 1].range.upperBound) + "|"
                }
                assigned[name] = out.count
                out.append(item(k, name, i, end, summary: summary))
                i = end + 1
                continue
            }
            i += 1
        }
        return out.sorted { ($0.fromLine, $0.kind) < ($1.fromLine, $1.kind) }
    }

    /// Environment variables and symbols in `tokens`, in order of first use.
    static func references(in tokens: [SCToken], u: [UInt16]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for tok in tokens where tok.kind == .environment || tok.kind == .symbol {
            var s = String(decoding: u[tok.range], as: UTF16.self)
            if tok.kind == .symbol, s.hasPrefix("'") { s = "\\" + s.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }

    /// FNV-1a over the code with runs of whitespace collapsed: a note goes
    /// stale when the code changes, not when it is re-indented.
    public static func hash(_ code: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        var space = false
        for b in code.utf8 {
            let isSpace = b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
            if isSpace { space = true; continue }
            if space { h ^= 0x20; h = h &* 0x100_0000_01b3; space = false }
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(String(h, radix: 16).suffix(8))
    }
}

/// `patch/dependencies/sc-lexicon.scd`: the SuperCollider Lexicon entries a
/// patch uses, written by Pondside like `lexicon.ily` for the score.
public enum SCLexiconInclude {
    public static let fileName = "sc-lexicon.scd"
    public static let marker = "// @pondside sc-lexicon"
    public static let loadLine = "\"dependencies/\(fileName)\".loadRelative;"

    public static func url(patch: URL) -> URL {
        patch.deletingLastPathComponent().appendingPathComponent("dependencies/\(fileName)")
    }

    /// The ids its marker line lists.
    public static func ids(in text: String) -> [String] {
        guard let l = text.components(separatedBy: "\n").first(where: { $0.hasPrefix(marker) }) else { return [] }
        return l.dropFirst(marker.count).split(separator: " ").map(String.init)
    }

    /// The patch with the include's load line after the engine's (in the
    /// first block), unless it is there already.
    public static func withLoadLine(_ patch: String) -> String {
        guard !patch.contains(loadLine) else { return patch }
        let engine = "\"\(HandlerSync.Layout.engineFile)\".loadRelative;"
        var lines = patch.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.contains(engine) }) {
            lines.insert(loadLine + "   // Pondside's SuperCollider Lexicon entries (sc_lexicon_add)", at: i + 1)
            return lines.joined(separator: "\n")
        }
        return loadLine + "\n" + patch
    }
}

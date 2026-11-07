import Foundation
import PondsideCore
import PondsideEngrave
import PondsideLexicon
import PondsideTiming

/// What the patch agent needs about a point in the score, in one answer
/// (docs/SUPERCOLLIDER.md, "The patch agent"): the cue there and its
/// handler's code (numbered), the cue's window, what the handler touches
/// (SynthDefs, patterns, buses, with their code), the pitch collections
/// around it, the patch doc (outline and notes), every cue, and the
/// SuperCollider Lexicon. With it the agent edits without searching.
public enum PatchContext {
    public struct Point: Sendable {
        public var bar: Int?
        public var moment: Rational?
        public var cue: String?
        /// Score seconds at the point, from the tempo map.
        public var seconds: Double?
        public init(bar: Int? = nil, moment: Rational? = nil, cue: String? = nil, seconds: Double? = nil) {
            self.bar = bar
            self.moment = moment
            self.cue = cue
            self.seconds = seconds
        }
    }

    /// Past this many seconds after its cue, a change at a point waits in
    /// the handler instead of happening on the cue.
    public static let waitThreshold = 0.5

    /// How the patch already waits inside its cue handlers (`2.5.wait`,
    /// `fork { … }`, `sched`), a few lines with their numbers, so a new wait
    /// matches them.
    static func waitExamples(_ outline: PatchOutline, patchDir: URL) -> [String] {
        var out: [String] = []
        let words = [".wait", "wait(", "yield", ".sched(", "fork"]
        for item in outline.items where item.kind == "cue" {
            guard let t = try? String(contentsOf: patchDir.appendingPathComponent(item.file), encoding: .utf8) else { continue }
            let lines = t.components(separatedBy: "\n")
            for n in item.fromLine...min(item.toLine, lines.count) {
                let l = lines[n - 1]
                let code = l.range(of: "//").map { String(l[..<$0.lowerBound]) } ?? l
                if words.contains(where: code.contains) {
                    out.append("\(item.file):\(n): " + l.trimmingCharacters(in: .whitespaces))
                    if out.count == 4 { return out }
                }
            }
        }
        return out
    }

    /// How many lines of touched code the context quotes in full.
    static let codeBudget = 300

    public static func describe(score: URL, patch: URL, sheet: CueSheet?, at point: Point,
                                collections: [Collections.Collection] = [], scoreContext: JSONValue? = nil,
                                lexicon: SCLexicon? = nil) -> JSONValue {
        var out: [String: JSONValue] = ["score": .string(score.path), "patch": .string(patch.path)]
        let doc: (text: String, stale: [String], outline: PatchOutline)
        if let d = try? PatchDoc.update(patch: patch) { doc = d } else {
            let o = PatchOutline.build(patch: patch)
            doc = (PatchDoc.render(outline: o, notes: [:], patchName: patch.lastPathComponent), [], o)
        }
        let outline = doc.outline
        var where_: [String: JSONValue] = [:]
        if let b = point.bar { where_["bar"] = .number(Double(b)) }
        if let m = point.moment { where_["moment"] = .string(m.description) }
        if let t = point.seconds { where_["seconds"] = .number((t * 1000).rounded() / 1000) }
        if let ev = scoreContext?["event"]?["text"] { where_["event"] = ev }
        if let staff = scoreContext?["staff"] { where_["staff"] = staff }
        out["point"] = .object(where_)

        let cues = sheet?.cues ?? []
        let index: Int? = {
            if let name = point.cue { return cues.firstIndex { $0.name == name || $0.id == name || $0.handler == name } }
            if let m = point.moment { return cues.lastIndex { (Rational(parsing: $0.position.moment) ?? .zero) <= m } }
            if let b = point.bar { return cues.lastIndex { $0.position.measure <= b } }
            return nil
        }()
        let patchDir = patch.deletingLastPathComponent()
        func text(of item: PatchOutline.Item) -> String? {
            let url = patchDir.appendingPathComponent(item.file)
            guard let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let lines = t.components(separatedBy: "\n")
            guard item.fromLine >= 1, item.fromLine <= lines.count else { return nil }
            return ScoreContext.numbered(lines[(item.fromLine - 1)..<min(item.toLine, lines.count)].joined(separator: "\n"), from: item.fromLine)
        }
        if let i = index {
            let c = cues[i]
            var cue: [String: JSONValue] = [
                "name": .string(c.name), "id": .string(c.id), "bar": .number(Double(c.position.measure)),
                "moment": .string(c.position.moment), "seconds": .number(c.seconds),
                "handler": .string("~cue[\\\(c.handler)]"),
            ]
            if let b = c.position.beat { cue["beat"] = .number(b) }
            // The exact time: a point well after its cue waits in the handler.
            if point.cue == nil, let t = point.seconds {
                let after = (max(0, t - c.seconds) * 1000).rounded() / 1000
                cue["point_after_cue"] = .number(after)
                if after > waitThreshold {
                    let examples = waitExamples(outline, patchDir: patch.deletingLastPathComponent())
                    cue["wait"] = .string(String(format: "The point is %.3f s after cue %@: don't start the change on the cue; wait %.3f s inside the handler first, ", after, c.name, after)
                        + (examples.isEmpty ? "e.g. `\(String(format: "%.3f", after)).wait;` before it (handlers run as routines on score seconds), or fork { … } around it if later code in the handler mustn't wait."
                           : "the way this patch already waits (lines below)."))
                    if !examples.isEmpty { cue["wait_examples"] = .array(examples.map(JSONValue.string)) }
                }
            }
            let end = i + 1 < cues.count ? cues[i + 1] : nil
            cue["window"] = .string(String(format: "%.2f", c.seconds) + "–" + (end.map { String(format: "%.2f s (until cue %@)", $0.seconds, $0.name) } ?? "the end"))
            if let item = outline.items.first(where: { $0.kind == "cue" && $0.name == c.id }) {
                cue["code"] = ["file": .string(item.file), "from_line": .number(Double(item.fromLine)),
                               "to_line": .number(Double(item.toLine)), "text": text(of: item).map(JSONValue.string) ?? .null]
                // What the handler uses, in full when short, so it can be changed in place.
                var budget = codeBudget
                let touched = outline.resolve(item.references).map { t -> JSONValue in
                    var o: [String: JSONValue] = ["item": .string(t.key), "at": .string(t.location)]
                    if !t.summary.isEmpty { o["summary"] = .string(t.summary) }
                    let n = t.toLine - t.fromLine + 1
                    if n <= 40, n <= budget, let code = text(of: t) {
                        budget -= n
                        o["text"] = .string(code)
                    }
                    return .object(o)
                }
                if !touched.isEmpty { cue["touches"] = .array(touched) }
            } else {
                cue["code"] = .string("no handler between Pondside's markers yet: the app adds a stub after the next engraving; or write ~cue[\\\(c.handler)] in the cue block")
            }
            out["cue"] = .object(cue)
            if let e = end { out["next_cue"] = ["name": .string(e.name), "seconds": .number(e.seconds), "bar": .number(Double(e.position.measure))] }
        } else if !cues.isEmpty {
            out["cue"] = .string("the point is before the first cue (\(cues[0].name), bar \(cues[0].position.measure)): what happens here belongs in cue \(cues[0].name) or setup")
        } else {
            out["cue"] = .string("the score has no cues: add \\ecue marks to the score (the graphics/score agent's job), or work in setup")
        }

        if !collections.isEmpty {
            let m = point.moment ?? index.flatMap { Rational(parsing: cues[$0].position.moment) }
            let before = m.flatMap { m in collections.lastIndex { $0.moment <= m } }
            let picked = [before, before.map { $0 + 1 } ?? 0].compactMap { $0 }.filter { $0 < collections.count }
            out["collections"] = .array(picked.map { k in
                let c = collections[k]
                return ["index": .number(Double(k)), "staff": .string(c.staff), "bar": .number(Double(c.bar)), "seconds": .number(c.seconds),
                        "pitch_classes": .array(c.pitchClasses.map { .number(Double($0)) }),
                        "midi": .array(c.midi.map { .number(Double($0)) }), "cue": c.cue.map(JSONValue.string) ?? .null]
            })
        }
        out["doc"] = .string(doc.text)
        if !doc.stale.isEmpty { out["stale_notes"] = .array(doc.stale.map(JSONValue.string)) }
        if !cues.isEmpty {
            out["cues"] = .array(cues.map { c in
                .string("\(c.name): bar \(c.position.measure)" + (c.position.beat.map { " beat \(ScoreContext.short($0))" } ?? "")
                        + ", \(ScoreContext.short(c.seconds)) s")
            })
        }
        if let lexicon {
            out["sc_lexicon"] = .array(lexicon.ids.compactMap { lexicon.entries[$0]?.indexLine }.map(JSONValue.string))
        }
        return .object(out)
    }

    /// Every staff's pitch collections, in time order.
    public static func collections(in log: TimingLog) -> [Collections.Collection] {
        Collections.all(in: log)
    }

    /// Writes `sc-lexicon.scd` for the patch's entries plus `ids`, and the
    /// load line into the patch. Returns the ids now included.
    @discardableResult
    public static func addLexicon(_ ids: [String], patch: URL, lexicon: SCLexicon) throws -> [String] {
        try addLexiconReportingShift(ids, patch: patch, lexicon: lexicon).ids
    }

    /// The same, with the line the load line went in at (nil when it was
    /// there already): every line after it moved down one.
    public static func addLexiconReportingShift(_ ids: [String], patch: URL, lexicon: SCLexicon) throws -> (ids: [String], insertedLine: Int?) {
        let include = SCLexiconInclude.url(patch: patch)
        let existing = (try? String(contentsOf: include, encoding: .utf8)).map(SCLexiconInclude.ids(in:)) ?? []
        let unknown = ids.filter { lexicon.entries[$0] == nil }
        guard unknown.isEmpty else {
            throw MCPServer.ToolFailure("no SuperCollider Lexicon entry \(unknown.joined(separator: ", ")); the entries: \(lexicon.ids.joined(separator: " "))")
        }
        let all = lexicon.closure(existing + ids.filter { !existing.contains($0) })
        let text = try String(contentsOf: patch, encoding: .utf8)
        let normalized = PatchContract.consolidate(text, score: patch.deletingPathExtension().lastPathComponent + ".ly")
        let with = SCLexiconInclude.withLoadLine(normalized)
        let includeText = lexicon.includeFile(for: all)
        let patchURL = patch.standardizedFileURL, includeURL = include.standardizedFileURL
        try PatchContract.validateProject(patch: patchURL, overrides: [patchURL: with, includeURL: includeText])
        try FileManager.default.createDirectory(at: include.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: include.path) { try Data().write(to: include, options: .withoutOverwriting) }
        let revisions = try Dictionary(uniqueKeysWithValues: [patchURL, includeURL].map { ($0, ContentHash(bytes: try Data(contentsOf: $0))) })
        try ProjectSourceTransaction.replace(expected: revisions, replacements: [patchURL: with, includeURL: includeText])
        guard with != text else { return (all, nil) }
        let line = with.components(separatedBy: "\n").firstIndex { $0.hasPrefix(SCLexiconInclude.loadLine) }.map { $0 + 1 }
        return (all, line)
    }
}

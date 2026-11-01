import Foundation
import PondsideCore
import PondsideLexicon
import PondsideTiming

/// What "here" means at a point in a score, as data an agent can act on
/// (DESIGN.md §8): the event there, its staff's music, its bar, and any
/// graphic it sits in. Computed from the files alone; the running app adds
/// what only the engraving knows (the system the point is on).
public enum ScoreContext {
    /// `line` is 1-based, `character` 0-based in Unicode scalars, as
    /// LilyPond's point-and-click and the app's selection give them.
    ///
    /// `files` are the score's files (path and text), searched for the
    /// definition of a graphic drawn by the score's own code; `cues` the
    /// latest cue sheet, listed so "till 7" can mean cue 7.
    public static func describe(text: String, file: String, line: Int, character: Int,
                                files: [ScoreGraphic.File] = [], cues: CueSheet? = nil) -> JSONValue {
        guard let offset = utf8Offset(in: text, line: line, character: character) else {
            return ["file": .string(file), "error": .string("no line \(line) in \(file)")]
        }
        let tree = SyntaxTree(text)
        var out: [String: JSONValue] = ["file": .string(file), "line": .number(Double(line)),
                                        "character": .number(Double(character))]
        // A command after an event (`s4*2 \startGrains`) belongs to that event.
        let eventIndex = tree.eventIndex(at: offset)
            ?? tree.events.lastIndex { $0.range.lowerBound <= offset && $0.postEvents.contains { $0.contains(offset) } }
            ?? tree.events.lastIndex { $0.range.upperBound <= offset }
        if let e = eventIndex {
            out["event"] = event(tree, e, text: text)
        }
        let block = LensBlockFinder.block(in: tree, at: offset)
        if let block, let e = eventIndex, let moments = ScoreGraphic.moments(of: block, in: tree), let m = moments[e] {
            out["moment"] = .string(m.description)
        }
        if let block {
            out["staff"] = block.label.map(JSONValue.string) ?? .null
            let firstLine = lineNumber(of: block.range.lowerBound, in: text)
            let lastLine = lineNumber(of: block.range.upperBound, in: text)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            // The staff's music, or the 40 lines around the point when it is long.
            let from = lastLine - firstLine > 40 ? max(firstLine, line - 20) : firstLine
            let to = lastLine - firstLine > 40 ? min(lastLine, line + 20) : lastLine
            out["music"] = ["from_line": .number(Double(from)), "to_line": .number(Double(to)),
                            "text": .string(numbered(lines[(from - 1)..<min(to, lines.count)].joined(separator: "\n"), from: from))]
        }
        if let window = LensScoreBuilder.build(tree: tree, selection: offset..<offset), let target = window.target {
            let bar = window.bars.lowerBound + target.measureIndex
            out["bar"] = .number(Double(bar))
        }
        // The clicked file first (its text as the caller has it), then the rest.
        let all = [(path: file, text: text)] + files.filter { $0.path != file }
        if let custom = ScoreGraphic.describe(at: offset, in: text, files: all) {
            out["graphic"] = custom
        } else if let graphic = graphic(around: offset, in: text) {
            out["graphic"] = graphic
        }
        if let cues, !cues.cues.isEmpty {
            out["cues"] = .array(cues.cues.map { c in
                .string("\(c.name): bar \(c.position.measure)" + (c.position.beat.map { " beat \(Self.short($0))" } ?? "")
                        + ", moment \(c.position.moment), \(Self.short(c.seconds)) s")
            })
        }
        return .object(out)
    }

    /// `text` with each line prefixed by its line number in the file
    /// (`412| …`), as the context quotes code: the agent edits by line
    /// without reading the file again. The prefix isn't part of the file.
    public static func numbered(_ text: String, from first: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let width = String(first + lines.count - 1).count
        return lines.enumerated().map { i, l in
            let n = String(first + i)
            return String(repeating: " ", count: width - n.count) + n + "| " + l
        }.joined(separator: "\n")
    }

    static func short(_ x: Double) -> String {
        x == x.rounded() ? String(Int(x)) : String(format: "%.2f", x).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func event(_ tree: SyntaxTree, _ e: Int, text: String) -> JSONValue {
        let ev = tree.events[e]
        let (l, c) = lineAndCharacter(of: ev.range.lowerBound, in: text)
        return ["text": .string(tree.string(ev.range)), "line": .number(Double(l)), "character": .number(Double(c)),
                "kind": .string(String(describing: ev.kind))]
    }

    /// The `\startGraphic` whose span holds `offset`: its entry, params and
    /// where it starts and stops.
    static func graphic(around offset: Int, in text: String) -> JSONValue? {
        let uses = LexiconUse.find(in: text).filter { $0.offset <= offset }
        let bytes = Array(text.utf8)
        let start = Array("\\startGraphic".utf8), stop = Array("\\stopGraphic".utf8)
        for use in uses.reversed() {
            guard bytes[use.offset...].starts(with: start) else { continue }
            // The first \stopGraphic after it.
            var i = use.offset + start.count
            while i + stop.count <= bytes.count, !bytes[i...].starts(with: stop) { i += 1 }
            guard i + stop.count <= bytes.count, i >= offset else { return nil }
            let (sl, sc) = lineAndCharacter(of: use.offset, in: text)
            let (el, ec) = lineAndCharacter(of: i, in: text)
            var params: [String: JSONValue] = [:]
            for (k, v) in use.params { params[k] = JSONValue.toml(v) }
            return ["entry": .string(use.id), "params": .object(params),
                    "start": ["line": .number(Double(sl)), "character": .number(Double(sc))],
                    "stop": ["line": .number(Double(el)), "character": .number(Double(ec))]]
        }
        return nil
    }

    // MARK: Positions

    public static func utf8Offset(in text: String, line: Int, character: Int) -> Int? {
        let source = SourceText(text)
        guard let index = source.index(of: SourcePosition(line: line, character: character)) else { return nil }
        return text.utf8.distance(from: text.startIndex, to: index)
    }

    public static func lineAndCharacter(of utf8: Int, in text: String) -> (Int, Int) {
        let index = text.utf8.index(text.startIndex, offsetBy: max(0, min(utf8, text.utf8.count)))
        let p = SourceText(text).position(of: index)
        return (p.line, p.character)
    }

    static func lineNumber(of utf8: Int, in text: String) -> Int { lineAndCharacter(of: utf8, in: text).0 }
}

extension JSONValue {
    static func toml(_ v: TOMLValue) -> JSONValue {
        switch v {
        case .string(let s): return .string(s)
        case .integer(let i): return .number(Double(i))
        case .float(let d): return .number(d)
        case .bool(let b): return .bool(b)
        case .array(let a): return .array(a.map(toml))
        case .table(let t): return .object(t.mapValues(toml))
        }
    }
}

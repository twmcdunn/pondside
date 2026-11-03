import Foundation
import PondsideCore
import PondsideTiming

/// A graphic drawn by the score's own code rather than the Lexicon: a
/// spanner command such as `\startGrains` whose stencil is a Scheme
/// procedure in one of the score's files. What an agent needs to change it
/// ("taller") without searching: the command, where it starts and stops,
/// its definition, the drawing procedure's text, what that uses, and the
/// comments that describe it.
public enum ScoreGraphic {
    public typealias File = (path: String, text: String)

    /// The `\command` word at `offset` (letters, digits and hyphens after a
    /// backslash), when the offset is on one.
    public static func commandRange(at offset: Int, in text: String) -> Range<Int>? {
        let b = Array(text.utf8)
        guard offset >= 0, offset < b.count else { return nil }
        var start = offset
        while start > 0, isWord(b[start]) { start -= 1 }
        guard b[start] == UInt8(ascii: "\\") else { return nil }
        var end = start + 1
        while end < b.count, isWord(b[end]) { end += 1 }
        guard end > start + 1, isLetter(b[start + 1]) else { return nil }
        return start..<end
    }

    /// How many lines of helper code the context quotes in full.
    static let helperLineBudget = 400

    static func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isWord(_ c: UInt8) -> Bool { isLetter(c) || (c >= 48 && c <= 57) || c == UInt8(ascii: "-") }

    /// The graphic whose start command is at `offset`, or nil when the word
    /// there isn't a `\start…` command defined in `files`.
    public static func describe(at offset: Int, in text: String, files: [File]) -> JSONValue? {
        // Paths beside the clicked file (files[0]) are given relative to it.
        let base = files.first.map { f in String(f.path[..<(f.path.lastIndex(of: "/") ?? f.path.startIndex)]) + "/" } ?? ""
        func relative(_ path: String) -> String { !base.isEmpty && path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path }
        guard let r = commandRange(at: offset, in: text) else { return nil }
        let name = String(decoding: Array(text.utf8)[(r.lowerBound + 1)..<r.upperBound], as: UTF8.self)
        guard name.hasPrefix("start"), name != "startGraphic", let def = definition(of: name, in: files) else { return nil }
        let (sl, sc) = ScoreContext.lineAndCharacter(of: r.lowerBound, in: text)
        var out: [String: JSONValue] = [
            "command": .string("\\" + name),
            "start": ["line": .number(Double(sl)), "character": .number(Double(sc))],
            "definition": def.json(relative),
        ]
        if let stop = stop(after: r.upperBound, in: text) {
            let (el, ec) = ScoreContext.lineAndCharacter(of: stop.lowerBound, in: text)
            out["stop"] = ["line": .number(Double(el)), "character": .number(Double(ec)),
                           "command": .string(String(decoding: Array(text.utf8)[stop], as: UTF8.self))]
        }
        // The procedures the definition names (its stencil), in full when
        // short enough to edit from, and what they in turn use.
        // The procedure only this graphic uses (its stencil) before shared
        // wrappers such as a `graphic-span` every command calls.
        let named = identifiers(in: def.text)
        let uses = Dictionary(uniqueKeysWithValues: named.map { id in (id, files.reduce(0) { $0 + $1.text.components(separatedBy: id).count - 1 }) })
        let drawings = named.sorted { uses[$0]! < uses[$1]! }.compactMap { procedure($0, in: files) }.prefix(2)
        if !drawings.isEmpty { out["drawing"] = .array(drawings.map { $0.json(relative) }) }
        // What the drawing calls, in full (numbered, so the agent edits by
        // line without reading the file): an agent given only signatures
        // reads each helper's file again, which is most of a slow turn.
        // Long ones, and what the helpers call in turn, by their first line.
        var seen = Set(drawings.map(\.name)).union([name])
        var helpers: [JSONValue] = []
        var budget = Self.helperLineBudget
        var second: [String] = []
        func add(_ id: String, full: Bool) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            if full, let found = procedure(id, in: files) ?? definition(of: id, in: files),
               found.endLine - found.line < 60, found.endLine - found.line < budget {
                budget -= found.endLine - found.line + 1
                helpers.append(found.json(relative))
                second += identifiers(in: found.text)
            } else if let found = definitionLine(of: id, in: files) {
                helpers.append(.string("\(id) \(relative(found.path)):\(found.line): \(found.text)"))
            }
        }
        for d in drawings {
            for id in identifiers(in: d.text) where helpers.count < 40 { add(id, full: true) }
        }
        for id in second where helpers.count < 40 { add(id, full: false) }
        if !helpers.isEmpty { out["uses"] = .array(helpers) }
        // The window recipe's prerequisites, so the agent never has to
        // search the project just to learn whether they already exist.
        var present: [JSONValue] = [], missing: [JSONValue] = []
        var span: Found?
        for id in ["g-span", "smoothstep", "system-moments", "section-window"] {
            if let found = procedure(id, in: files) ?? definition(of: id, in: files) {
                present.append(.string(id))
                if id == "g-span" { span = found }
            } else {
                missing.append(.string(id))
            }
        }
        var support: [String: JSONValue] = ["present": .array(present), "missing": .array(missing),
                                            "ready": .bool(missing.isEmpty)]
        if let anchor = span ?? drawings.first {
            support["file"] = .string(relative(anchor.path))
            support["insert_after_line"] = .number(Double(anchor.endLine))
        }
        out["section_support"] = .object(support)
        let notes = comments(mentioning: "\\" + name, in: files)
        if !notes.isEmpty { out["notes"] = .string(notes) }
        return .object(out)
    }

    // MARK: Definitions

    struct Found {
        var name: String
        var path: String
        var line: Int
        var endLine: Int
        var text: String
        /// The comment block just above it.
        var comment: String

        func json(_ relative: (String) -> String) -> JSONValue {
            var o: [String: JSONValue] = ["name": .string(name), "file": .string(relative(path)),
                                          "from_line": .number(Double(line)), "to_line": .number(Double(endLine))]
            if !comment.isEmpty { o["comment"] = .string(comment) }
            // Numbered as the file is; long procedures by range only.
            if endLine - line < 150 { o["text"] = .string(ScoreContext.numbered(text, from: line)) }
            return .object(o)
        }
    }

    /// `name = …` at the start of a line, with its continuation lines.
    static func definition(of name: String, in files: [File]) -> Found? {
        for f in files {
            let lines = f.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, l) in lines.enumerated() {
                guard l.hasPrefix(name), l.dropFirst(name.count).drop(while: { $0 == " " }).first == "=" else { continue }
                return block(lines, from: i, name: name, path: f.path)
            }
        }
        return nil
    }

    /// `#(define (name …` or `#(define* (name …` at the start of a line.
    static func procedure(_ name: String, in files: [File]) -> Found? {
        for f in files {
            let lines = f.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, l) in lines.enumerated() where defines(l, name) {
                return block(lines, from: i, name: name, path: f.path)
            }
        }
        return nil
    }

    static func defines(_ line: Substring, _ name: String) -> Bool {
        for head in ["#(define (", "#(define* (", "#(define "] where line.hasPrefix(head) {
            let rest = line.dropFirst(head.count)
            guard rest.hasPrefix(name) else { continue }
            let after = rest.dropFirst(name.count).first
            if after == nil || after == " " || after == ")" { return true }
        }
        return false
    }

    /// The line that defines `name` (a procedure, a value or a command).
    static func definitionLine(of name: String, in files: [File]) -> (path: String, line: Int, text: String)? {
        for f in files {
            for (i, l) in f.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if defines(l, name) || (l.hasPrefix(name) && l.dropFirst(name.count).drop(while: { $0 == " " }).first == "=") {
                    return (f.path, i + 1, String(l.prefix(120)))
                }
            }
        }
        return nil
    }

    /// From `start` to the line before the next one at column 0 (the
    /// body of a definition is indented), trailing blank lines dropped.
    static func block(_ lines: [Substring], from start: Int, name: String, path: String) -> Found {
        var end = start
        var i = start + 1
        while i < lines.count {
            let l = lines[i]
            if let c = l.first, c != " ", c != "\t", c != ")" { break }
            if !l.allSatisfy(\.isWhitespace) { end = i }
            i += 1
        }
        var j = start - 1
        var comment: [Substring] = []
        while j >= 0, lines[j].hasPrefix("%") || lines[j].hasPrefix("#!") {
            comment.insert(lines[j], at: 0)
            j -= 1
        }
        return Found(name: name, path: path, line: start + 1, endLine: end + 1,
                     text: lines[start...end].joined(separator: "\n"),
                     comment: comment.suffix(12).joined(separator: "\n"))
    }

    /// Scheme identifiers in `text`, in order of first use: what a
    /// definition calls or reads.
    static func identifiers(in text: String) -> [String] {
        var out: [String] = [], seen = Set<String>()
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count > 2, current.first!.isLetter, !seen.contains(current),
                  !schemeWords.contains(current), !current.hasPrefix("ly:") else { return }
            seen.insert(current)
            out.append(current)
        }
        var inComment = false
        for ch in text {
            if ch == "\n" { inComment = false }
            if inComment { continue }
            if ch == ";" { flush(); inComment = true; continue }
            if ch.isLetter || ch.isNumber || "-*?!<>=/:".contains(ch) { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    static let schemeWords: Set<String> = [
        "define", "define*", "lambda", "let", "let*", "letrec", "if", "cond", "else", "and", "or", "not", "begin",
        "map", "filter", "filter-map", "apply", "list", "cons", "car", "cdr", "cadr", "caar", "cdar", "cddr",
        "length", "append", "reverse", "max", "min", "abs", "expt", "sqrt", "sin", "cos", "round", "floor",
        "random", "loop", "set!", "null?", "pair?", "number?", "for-each", "iota", "assq", "assv", "assoc",
        "list-ref", "vector-ref", "last", "exact->inexact", "inexact->exact", "quote", "grob", "when", "unless",
        "do", "case", "string-append", "format", "display", "eq?", "equal?", "memq", "memv", "member", "zero?",
    ]

    /// The next `\stop…` command after `offset`.
    static func stop(after offset: Int, in text: String) -> Range<Int>? {
        let b = Array(text.utf8), needle = Array("\\stop".utf8)
        var i = offset
        while i + needle.count < b.count {
            if b[i] == needle[0], Array(b[i..<(i + needle.count)]) == needle, isLetter(b[i + needle.count]) {
                var end = i + needle.count
                while end < b.count, isWord(b[end]) { end += 1 }
                return i..<end
            }
            i += 1
        }
        return nil
    }

    /// Comment lines that mention the command (a file's table of its
    /// graphics), each with the indented comment lines continuing it.
    static func comments(mentioning word: String, in files: [File]) -> String {
        var out: [String] = []
        for f in files {
            let lines = f.text.split(separator: "\n", omittingEmptySubsequences: false)
            var i = 0
            while i < lines.count {
                let l = lines[i]
                guard l.hasPrefix("%"), let r = l.range(of: word),
                      l[r.upperBound...].first.map({ !isWordCharacter($0) }) ?? true else { i += 1; continue }
                out.append(String(l))
                let column = l.distance(from: l.startIndex, to: r.lowerBound)
                i += 1
                // Continuation: comment lines indented past the command.
                while i < lines.count, lines[i].hasPrefix("%"),
                      lines[i].dropFirst().prefix(while: { $0 == " " }).count + 1 > column, out.count < 16 {
                    out.append(String(lines[i]))
                    i += 1
                }
            }
        }
        return out.prefix(16).joined(separator: "\n")
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" }

    // MARK: Moments

    /// The moment (whole notes from the start of the staff's music) at
    /// which each event of `block` starts, when the block is plain enough
    /// to count: no tuplets, repeats, grace notes or nested voices.
    public static func moments(of block: LensBlock, in tree: SyntaxTree) -> [Int: Rational]? {
        let body = tree.string(block.range)
        for word in ["\\tuplet", "\\times", "\\repeat", "\\grace", "\\acciaccatura", "\\appoggiatura",
                     "\\afterGrace", "\\scaleDurations", "<<"] where body.contains(word) {
            return nil
        }
        var out: [Int: Rational] = [:]
        var t = Rational.zero
        for e in block.events.sorted() {
            out[e] = t
            let (n, d) = tree.events[e].effectiveDuration.wholeNotes
            t = t + Rational(n, d)
        }
        return out
    }
}

import Foundation

/// The `edit` tool's edits: exact text, or whole lines as score_context and
/// patch_context number them, applied together or not at all. An agent
/// given numbered code edits without reading the file first (the
/// harnesses' own edit tools insist on a read), which saves a turn.
public enum FileEdit {
    public struct Change: Sendable {
        public var old: String?
        public var new: String
        public var fromLine: Int?
        public var toLine: Int?
        public init(old: String? = nil, new: String, fromLine: Int? = nil, toLine: Int? = nil) {
            self.old = old
            self.new = new
            self.fromLine = fromLine
            self.toLine = toLine
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        init(_ d: String) { description = d }
    }

    /// The new text, and the lines (in it) the edits cover.
    public static func apply(_ changes: [Change], to text: String) throws -> (text: String, lines: ClosedRange<Int>) {
        guard !changes.isEmpty else { throw Failure("no edits") }
        var ranges: [(range: Range<String.Index>, new: String)] = []
        let starts = lineStarts(text)
        for (n, c) in changes.enumerated() {
            let label = changes.count > 1 ? "edit \(n + 1): " : ""
            if let from = c.fromLine {
                let to = c.toLine ?? from
                guard from >= 1, to >= from, to <= starts.count else {
                    throw Failure("\(label)lines \(from)–\(to) aren't in the file (it has \(starts.count))")
                }
                let lower = starts[from - 1]
                // The end of line `to`, before its newline.
                let upper = text[starts[to - 1]...].firstIndex(of: "\n") ?? text.endIndex
                // With old too, the lines must still say it: a context's line
                // numbers go stale when an earlier edit added lines.
                if let old = c.old, !old.isEmpty {
                    let now = String(text[lower..<upper])
                    let expected = unnumbered(old) ?? old
                    guard now.trimmingCharacters(in: .whitespacesAndNewlines) == expected.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        let found = occurrences(of: expected, in: text).map { String(line(of: $0.lowerBound, in: text, starts: starts)) }
                        throw Failure("\(label)lines \(from)–\(to) are now:\n\(now)\n" + (found.isEmpty ? "and old isn't anywhere in the file"
                            : "old is at line \(found.joined(separator: ", ")): the file has moved since the context; use those lines"))
                    }
                }
                ranges.append((lower..<upper, unnumbered(c.new) ?? c.new))
            } else if let old = c.old, !old.isEmpty {
                var found = occurrences(of: old, in: text)
                var new = c.new
                if found.isEmpty, let plain = unnumbered(old) {
                    // Copied with the context's line numbers.
                    found = occurrences(of: plain, in: text)
                    new = unnumbered(c.new) ?? c.new
                }
                guard !found.isEmpty else {
                    let expected = unnumbered(old) ?? old
                    if let near = whitespaceNormalizedMatch(of: expected, in: text, starts: starts) {
                        let actual = String(text[near.range])
                        let shown = actual.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
                        throw Failure("\(label)old text differs only in whitespace from lines \(near.lines.lowerBound)–\(near.lines.upperBound):\n"
                            + ScoreContext.numbered(shown, from: near.lines.lowerBound)
                            + "\nUse from_line/to_line with old copied exactly as a guard. All ranges in one call address the same original snapshot.")
                    }
                    throw Failure("\(label)old text not found; use from_line/to_line from the numbered context (all ranges in one call address the same original snapshot), or copy old exactly without line numbers")
                }
                guard found.count == 1 else {
                    let lines = found.map { String(line(of: $0.lowerBound, in: text, starts: starts)) }.joined(separator: ", ")
                    throw Failure("\(label)old text is on lines \(lines): include more of it, or give from_line/to_line")
                }
                ranges.append((found[0], new))
            } else {
                throw Failure("\(label)give old (with new), or from_line (and to_line) with new")
            }
        }
        let sorted = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.range.lowerBound < a.range.upperBound {
            throw Failure("two edits overlap (lines \(line(of: a.range.lowerBound, in: text, starts: starts)) and \(line(of: b.range.lowerBound, in: text, starts: starts)))")
        }
        var out = text
        for r in sorted.reversed() { out.replaceSubrange(r.range, with: r.new) }
        // Where the edits landed, in the new text.
        let firstLine = line(of: sorted[0].range.lowerBound, in: text, starts: starts)
        var shift = 0
        for r in sorted.dropLast() { shift += r.new.filter { $0 == "\n" }.count - text[r.range].filter { $0 == "\n" }.count }
        let last = sorted[sorted.count - 1]
        let lastLine = line(of: last.range.lowerBound, in: text, starts: starts) + shift + last.new.filter { $0 == "\n" }.count
        return (out, firstLine...max(firstLine, lastLine))
    }

    static func lineStarts(_ text: String) -> [String.Index] {
        var out = [text.startIndex]
        var i = text.startIndex
        while let nl = text[i...].firstIndex(of: "\n") {
            i = text.index(after: nl)
            out.append(i)
        }
        if out.count > 1, out.last == text.endIndex { out.removeLast() }
        return out
    }

    static func line(of index: String.Index, in text: String, starts: [String.Index]) -> Int {
        (starts.lastIndex { $0 <= index } ?? 0) + 1
    }

    static func occurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            out.append(r)
            from = text.index(after: r.lowerBound)
        }
        return out
    }

    /// A unique match whose only difference is whitespace, for an actionable
    /// error. It is never applied implicitly: exact source edits stay exact.
    static func whitespaceNormalizedMatch(of needle: String, in text: String,
                                          starts: [String.Index]) -> (range: Range<String.Index>, lines: ClosedRange<Int>)? {
        func normalized(_ line: String) -> String {
            line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let expected = needle.split(separator: "\n", omittingEmptySubsequences: false).map { normalized(String($0)) }
        guard !expected.isEmpty, expected.contains(where: { !$0.isEmpty }) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { normalized(String($0)) }
        guard starts.count >= expected.count else { return nil }
        var found: [(range: Range<String.Index>, lines: ClosedRange<Int>)] = []
        for i in 0...(starts.count - expected.count) where Array(lines[i..<(i + expected.count)]) == expected {
            let lower = starts[i]
            let last = i + expected.count - 1
            let upper = text[starts[last]...].firstIndex(of: "\n") ?? text.endIndex
            found.append((lower..<upper, (i + 1)...(last + 1)))
        }
        return found.count == 1 ? found[0] : nil
    }

    /// `text` without the `412| ` prefixes the contexts add, if every
    /// non-empty line has one.
    static func unnumbered(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for l in lines {
            let trimmed = l.drop { $0 == " " }
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix("|") else {
                if l.allSatisfy(\.isWhitespace) { out.append(l); continue }
                return nil
            }
            var rest = trimmed.dropFirst(digits.count + 1)
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            out.append(String(rest))
        }
        return out.joined(separator: "\n")
    }
}

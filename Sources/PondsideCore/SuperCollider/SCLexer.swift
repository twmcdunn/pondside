/// A small SuperCollider lexer for colouring, region finding and
/// completion. It works on UTF-16 code units so ranges map straight onto
/// the text view; sclang's syntax is ASCII outside strings and comments.
public enum SCTokenKind: String, Sendable, Hashable {
    case comment, string, symbol, character, number
    case className, keyword, builtin, environment, primitive, identifier
    case openParen, closeParen, openBracket, closeBracket, openBrace, closeBrace
    case punctuation, whitespace
}

public struct SCToken: Hashable, Sendable {
    public var kind: SCTokenKind
    /// UTF-16 offsets.
    public var range: Range<Int>

    public init(_ kind: SCTokenKind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

public enum SCLexer {
    public static let keywords: Set<String> = [
        "arg", "var", "classvar", "const", "this", "super", "thisProcess", "thisThread",
        "thisMethod", "thisFunction", "thisFunctionDef",
    ]
    public static let builtins: Set<String> = ["nil", "true", "false", "inf", "pi", "currentEnvironment", "topEnvironment"]

    public static func tokenize(_ text: String) -> [SCToken] { tokenize(Array(text.utf16)) }

    public static func tokenize(_ u: [UInt16]) -> [SCToken] {
        var out: [SCToken] = []
        var i = 0
        let n = u.count
        func at(_ k: Int) -> UInt16 { k < n ? u[k] : 0 }
        while i < n {
            let start = i
            let c = u[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                while i < n, [0x20, 0x09, 0x0A, 0x0D].contains(u[i]) { i += 1 }
                out.append(SCToken(.whitespace, start..<i))
            case 0x2F where at(i + 1) == 0x2F: // //
                while i < n, u[i] != 0x0A { i += 1 }
                out.append(SCToken(.comment, start..<i))
            case 0x2F where at(i + 1) == 0x2A: // /* nests in sclang
                var depth = 0
                while i < n {
                    if u[i] == 0x2F, at(i + 1) == 0x2A { depth += 1; i += 2 }
                    else if u[i] == 0x2A, at(i + 1) == 0x2F { depth -= 1; i += 2; if depth == 0 { break } }
                    else { i += 1 }
                }
                out.append(SCToken(.comment, start..<i))
            case 0x22, 0x27: // "string", 'symbol'
                i += 1
                while i < n, u[i] != c {
                    i += u[i] == 0x5C ? 2 : 1
                }
                i = min(i + 1, n)
                out.append(SCToken(c == 0x22 ? .string : .symbol, start..<i))
            case 0x5C where isIdentStart(at(i + 1)) || isDigit(at(i + 1)): // \symbol
                i += 1
                while i < n, isIdentPart(u[i]) { i += 1 }
                out.append(SCToken(.symbol, start..<i))
            case 0x24 where i + 1 < n: // $c, $\n
                i += at(i + 1) == 0x5C ? 3 : 2
                i = min(i, n)
                out.append(SCToken(.character, start..<i))
            case 0x7E where isIdentStart(at(i + 1)): // ~env
                i += 1
                while i < n, isIdentPart(u[i]) { i += 1 }
                out.append(SCToken(.environment, start..<i))
            case 0x5F where isIdentStart(at(i + 1)) && (start == 0 || !isIdentPart(u[start - 1])): // _Primitive
                i += 1
                while i < n, isIdentPart(u[i]) { i += 1 }
                out.append(SCToken(.primitive, start..<i))
            case _ where isDigit(c):
                i = number(u, from: i)
                out.append(SCToken(.number, start..<i))
            case _ where isIdentStart(c):
                while i < n, isIdentPart(u[i]) { i += 1 }
                let word = String(decoding: u[start..<i], as: UTF16.self)
                let kind: SCTokenKind
                if isUpper(c) { kind = .className }
                else if keywords.contains(word) { kind = .keyword }
                else if builtins.contains(word) { kind = .builtin }
                else { kind = .identifier }
                out.append(SCToken(kind, start..<i))
            default:
                i += 1
                let kind: SCTokenKind
                switch c {
                case 0x28: kind = .openParen
                case 0x29: kind = .closeParen
                case 0x5B: kind = .openBracket
                case 0x5D: kind = .closeBracket
                case 0x7B: kind = .openBrace
                case 0x7D: kind = .closeBrace
                default: kind = .punctuation
                }
                out.append(SCToken(kind, start..<i))
            }
        }
        return out
    }

    /// 12, 1.5, 1e-3, 0x1F, 2r1010, 36rZZ, 3pi.
    static func number(_ u: [UInt16], from start: Int) -> Int {
        var i = start
        let n = u.count
        while i < n, isDigit(u[i]) { i += 1 }
        if i < n, u[i] == 0x72 /* r */, i + 1 < n, isAlnum(u[i + 1]) {
            i += 1
            while i < n, isAlnum(u[i]) || u[i] == 0x2E { i += 1 }
            return i
        }
        if i + 1 < n, u[i] == 0x78 /* x */, start + 1 == i, u[start] == 0x30 {
            i += 1
            while i < n, isAlnum(u[i]) { i += 1 }
            return i
        }
        if i + 1 < n, u[i] == 0x2E, isDigit(u[i + 1]) {
            i += 1
            while i < n, isDigit(u[i]) { i += 1 }
        }
        if i < n, u[i] == 0x65 /* e */ {
            var j = i + 1
            if j < n, u[j] == 0x2D || u[j] == 0x2B { j += 1 }
            if j < n, isDigit(u[j]) {
                i = j
                while i < n, isDigit(u[i]) { i += 1 }
            }
        }
        if i + 1 < n, u[i] == 0x70, u[i + 1] == 0x69, !(i + 2 < n && isIdentPart(u[i + 2])) { i += 2 } // 2pi
        return i
    }

    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    static func isLower(_ c: UInt16) -> Bool { c >= 0x61 && c <= 0x7A }
    static func isAlnum(_ c: UInt16) -> Bool { isDigit(c) || isUpper(c) || isLower(c) }
    static func isIdentStart(_ c: UInt16) -> Bool { isUpper(c) || isLower(c) }
    static func isIdentPart(_ c: UInt16) -> Bool { isAlnum(c) || c == 0x5F }
}

/// Which code ⌘↩ and ⇧↩ send to the interpreter.
public enum SCRegion {
    /// The selection if there is one; else the outermost `( … )` around the
    /// caret whose `(` starts its line, as in the SuperCollider IDE; else
    /// the caret's line. UTF-16 offsets.
    public static func evaluationRange(in text: String, selection: Range<Int>) -> Range<Int> {
        let u = Array(text.utf16)
        if !selection.isEmpty { return selection }
        return block(in: u, caret: selection.lowerBound) ?? line(in: u, caret: selection.lowerBound)
    }

    /// The caret's line, without its newline.
    public static func line(in text: String, caret: Int) -> Range<Int> { line(in: Array(text.utf16), caret: caret) }

    static func line(in u: [UInt16], caret: Int) -> Range<Int> {
        let c = min(max(caret, 0), u.count)
        var s = c
        while s > 0, u[s - 1] != 0x0A { s -= 1 }
        var e = c
        while e < u.count, u[e] != 0x0A { e += 1 }
        return s..<e
    }

    static func block(in u: [UInt16], caret: Int) -> Range<Int>? {
        var best: Range<Int>?
        for pair in parenPairs(u) where pair.open <= caret && caret <= pair.close + 1 && startsLine(u, pair.open) {
            if best == nil || pair.open < best!.lowerBound { best = pair.open..<(pair.close + 1) }
        }
        return best
    }

    static func startsLine(_ u: [UInt16], _ i: Int) -> Bool {
        var k = i
        while k > 0 {
            k -= 1
            if u[k] == 0x0A { return true }
            if u[k] != 0x20 && u[k] != 0x09 { return false }
        }
        return true
    }

    /// Matched round brackets, skipping strings, symbols, characters and
    /// comments. Unbalanced brackets are ignored.
    static func parenPairs(_ u: [UInt16]) -> [(open: Int, close: Int)] {
        var stack: [Int] = []
        var pairs: [(open: Int, close: Int)] = []
        for t in SCLexer.tokenize(u) {
            switch t.kind {
            case .openParen: stack.append(t.range.lowerBound)
            case .closeParen: if let o = stack.popLast() { pairs.append((o, t.range.lowerBound)) }
            default: break
            }
        }
        return pairs
    }

    /// The file's top-level `( … )` blocks whose `(` starts a line, in
    /// order: what a person runs one by one with ⌘↩. UTF-16 offsets, the
    /// brackets included.
    public static func topLevelBlocks(in text: String) -> [Range<Int>] {
        let u = Array(text.utf16)
        let pairs = parenPairs(u).filter { startsLine(u, $0.open) }.sorted { $0.open < $1.open }
        var out: [Range<Int>] = []
        for p in pairs where !(out.last.map { $0.contains(p.open) } ?? false) {
            out.append(p.open..<(p.close + 1))
        }
        return out
    }

    /// The bracket matching the one at `offset`, if any.
    public static func matchingBracket(in text: String, at offset: Int) -> Int? {
        let tokens = SCLexer.tokenize(text)
        guard let i = tokens.firstIndex(where: { $0.range.lowerBound == offset }) else { return nil }
        let opens: [SCTokenKind: SCTokenKind] = [.openParen: .closeParen, .openBracket: .closeBracket, .openBrace: .closeBrace]
        let closes = Dictionary(uniqueKeysWithValues: opens.map { ($1, $0) })
        let k = tokens[i].kind
        if let close = opens[k] {
            var depth = 0
            for t in tokens[i...] {
                if t.kind == k { depth += 1 } else if t.kind == close { depth -= 1; if depth == 0 { return t.range.lowerBound } }
            }
        } else if let open = closes[k] {
            var depth = 0
            for t in tokens[...i].reversed() {
                if t.kind == k { depth += 1 } else if t.kind == open { depth -= 1; if depth == 0 { return t.range.lowerBound } }
            }
        }
        return nil
    }
}

/// The class library of a running sclang, as far as completion and
/// signature help need it: classes, their superclasses, help summaries and
/// methods with argument names and defaults.
///
/// sclang writes it as tab-separated lines (`SCLangSession.libraryDumpCode`):
///
///     C <class> <superclass> <summary>
///     M <class> c|i <method> <arg>[=<default>],…
public struct SCClassLibrary: Sendable, Hashable {
    public struct Argument: Sendable, Hashable {
        public var name: String
        public var defaultValue: String?
    }

    public struct Method: Sendable, Hashable {
        public var name: String
        public var owner: String
        public var isClassMethod: Bool
        public var arguments: [Argument]

        /// `SinOsc.ar(freq: 440.0, phase: 0.0)` or `Object.postln`.
        public var signature: String {
            let head = owner + (isClassMethod ? "." : ":") + name
            guard !arguments.isEmpty else { return head }
            return head + "(" + argumentList() + ")"
        }

        public func argumentList(highlighting active: Int? = nil) -> String {
            arguments.enumerated().map { i, a in
                let s = a.name + (a.defaultValue.map { ": " + $0 } ?? "")
                return i == active ? "‹" + s + "›" : s
            }.joined(separator: ", ")
        }
    }

    public struct ClassInfo: Sendable, Hashable {
        public var name: String
        public var superclass: String?
        public var summary: String
        public var classMethods: [String: Method] = [:]
        public var instanceMethods: [String: Method] = [:]
    }

    public private(set) var classes: [String: ClassInfo] = [:]
    /// Instance method name → the classes that define it.
    public private(set) var implementors: [String: [String]] = [:]

    public init() {}

    public init(tsv: String) {
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "C", f.count >= 3 {
                let name = f[1]
                var info = classes[name] ?? ClassInfo(name: name, superclass: nil, summary: "")
                info.superclass = f[2].isEmpty ? nil : f[2]
                info.summary = f.count > 3 ? f[3] : ""
                classes[name] = info
            } else if f.first == "M", f.count >= 4 {
                let cls = f[1], isClass = f[2] == "c", name = f[3]
                let args: [Argument] = f.count > 4 && !f[4].isEmpty ? f[4].split(separator: ",").map { part in
                    if let eq = part.firstIndex(of: "=") {
                        return Argument(name: String(part[..<eq]), defaultValue: String(part[part.index(after: eq)...]))
                    }
                    return Argument(name: String(part), defaultValue: nil)
                } : []
                let m = Method(name: name, owner: cls, isClassMethod: isClass, arguments: args)
                var info = classes[cls] ?? ClassInfo(name: cls, superclass: nil, summary: "")
                if isClass { info.classMethods[name] = m } else {
                    info.instanceMethods[name] = m
                    implementors[name, default: []].append(cls)
                }
                classes[cls] = info
            }
        }
    }

    public var isEmpty: Bool { classes.isEmpty }

    /// `name` and its superclasses, nearest first.
    public func lineage(_ name: String) -> [String] {
        var out: [String] = []
        var current: String? = name
        while let c = current, let info = classes[c], !out.contains(c) {
            out.append(c)
            current = info.superclass
        }
        return out
    }

    /// Methods an instance of `name` responds to, nearest definition winning.
    public func instanceMethods(of name: String) -> [Method] {
        var seen: [String: Method] = [:]
        for c in lineage(name) { for (k, m) in classes[c]?.instanceMethods ?? [:] where seen[k] == nil { seen[k] = m } }
        return Array(seen.values)
    }

    /// Methods the class object `name` responds to: its class methods up
    /// the chain, then what every class inherits from `Class` and `Object`.
    public func classMethods(of name: String) -> [Method] {
        var seen: [String: Method] = [:]
        for c in lineage(name) { for (k, m) in classes[c]?.classMethods ?? [:] where seen[k] == nil { seen[k] = m } }
        for m in instanceMethods(of: "Class") where seen[m.name] == nil { seen[m.name] = m }
        return Array(seen.values)
    }

    public func method(_ name: String, of cls: String, classSide: Bool) -> Method? {
        (classSide ? classMethods(of: cls) : instanceMethods(of: cls)).first { $0.name == name }
    }
}

/// What the caret is in the middle of, for completion and signature help.
public enum SCCompletion {
    public enum Kind: String, Sendable, Hashable { case className, method, variable, keyword, environment }

    public struct Item: Sendable, Hashable {
        public var label: String
        public var kind: Kind
        /// Signature or summary, shown beside the label.
        public var detail: String
    }

    public struct Result: Sendable, Hashable {
        /// The UTF-16 range the chosen label replaces (the typed prefix).
        public var replacing: Range<Int>
        public var items: [Item]
    }

    /// The receiver before a `.`, as far as the text shows it.
    public enum Receiver: Hashable, Sendable {
        case classObject(String)
        case instance(String)
        case unknown
    }

    /// Completions at `caret`. With `explicit` false (typing) nothing is
    /// offered until there is a `.` or two letters to go on.
    public static func complete(_ text: String, caret: Int, library: SCClassLibrary, explicit: Bool = false) -> Result? {
        let u = Array(text.utf16)
        let caret = min(max(caret, 0), u.count)
        let tokens = SCLexer.tokenize(u)
        if let t = tokens.first(where: { $0.range.lowerBound < caret && caret <= $0.range.upperBound }),
           [.comment, .string, .symbol, .character].contains(t.kind),
           caret < t.range.upperBound || isOpenEnded(t, u) {
            return nil
        }
        var p = caret
        while p > 0, SCLexer.isIdentPart(u[p - 1]) { p -= 1 }
        let prefix = String(decoding: u[p..<caret], as: UTF16.self)
        if p < caret, SCLexer.isDigit(u[p]) { return nil }
        let before: UInt16 = p > 0 ? u[p - 1] : 0

        var items: [Item] = []
        if before == 0x7E { // ~env
            var names = Set<String>()
            for t in tokens where t.kind == .environment && t.range.upperBound != caret {
                names.insert(String(decoding: u[(t.range.lowerBound + 1)..<t.range.upperBound], as: UTF16.self))
            }
            items = names.map { Item(label: $0, kind: .environment, detail: "environment variable") }
        } else if before == 0x2E, p >= 2, u[p - 2] != 0x2E { // receiver.
            let methods: [SCClassLibrary.Method]
            switch receiver(before: p - 1, tokens: tokens, u: u) {
            case .classObject(let c): methods = library.classMethods(of: c)
            case .instance(let c): methods = library.instanceMethods(of: c)
            case .unknown:
                methods = library.implementors.compactMap { name, owners in
                    owners.count == 1 ? library.classes[owners[0]]?.instanceMethods[name]
                        : library.classes[owners.sorted()[0]]?.instanceMethods[name].map { m in
                            var m = m
                            m.owner = "\(owners.count) classes"
                            return m
                        }
                }
            }
            items = methods.filter { isIdentifier($0.name) && ($0.name.last != "_" || prefix.hasSuffix("_")) }.map {
                Item(label: $0.name, kind: .method,
                     detail: $0.arguments.isEmpty ? $0.owner : "(" + $0.argumentList() + ")  " + $0.owner)
            }
        } else {
            guard explicit || prefix.utf16.count >= 2 else { return nil }
            if let first = prefix.utf16.first, SCLexer.isUpper(first) {
                items = library.classes.values.map { Item(label: $0.name, kind: .className, detail: $0.summary) }
            } else {
                var names = Set<String>()
                for t in tokens where t.kind == .identifier && t.range.upperBound != caret {
                    names.insert(String(decoding: u[t.range], as: UTF16.self))
                }
                items = names.map { Item(label: $0, kind: .variable, detail: "") }
                items += (SCLexer.keywords.union(SCLexer.builtins)).map { Item(label: $0, kind: .keyword, detail: "") }
            }
        }
        return Result(replacing: p..<caret, items: rank(items, prefix: prefix))
    }

    /// Prefix matches, exact case first, then shorter, then alphabetical.
    static func rank(_ items: [Item], prefix: String) -> [Item] {
        let lower = prefix.lowercased()
        let matching = items.filter { $0.label != prefix && $0.label.lowercased().hasPrefix(lower) }
        var unique: [String: Item] = [:]
        for i in matching where unique[i.label] == nil { unique[i.label] = i }
        return unique.values.sorted { a, b in
            let ea = a.label.hasPrefix(prefix), eb = b.label.hasPrefix(prefix)
            if ea != eb { return ea }
            if a.label.count != b.label.count { return a.label.count < b.label.count }
            return a.label < b.label
        }.prefix(300).map { $0 }
    }

    /// A line comment, or a string or quoted symbol still missing its
    /// closing quote: typing at its end is still inside it.
    static func isOpenEnded(_ t: SCToken, _ u: [UInt16]) -> Bool {
        switch t.kind {
        case .comment: return u[t.range.lowerBound + 1] == 0x2F
        case .string, .symbol:
            let q = u[t.range.lowerBound]
            guard q == 0x22 || q == 0x27 else { return false }
            return t.range.count < 2 || u[t.range.upperBound - 1] != q
        default: return false
        }
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let f = s.utf16.first, SCLexer.isIdentStart(f) else { return false }
        return s.utf16.allSatisfy(SCLexer.isIdentPart)
    }

    /// Classifies the expression ending just before `dot`.
    static func receiver(before dot: Int, tokens: [SCToken], u: [UInt16]) -> Receiver {
        guard let i = tokens.lastIndex(where: { $0.range.upperBound <= dot && $0.kind != .whitespace }),
              tokens[i].range.upperBound == dot else { return .unknown }
        let t = tokens[i]
        let text = String(decoding: u[t.range], as: UTF16.self)
        switch t.kind {
        case .className: return .classObject(text)
        case .string: return .instance("String")
        case .symbol: return .instance("Symbol")
        case .character: return .instance("Char")
        case .number: return .instance(text.contains(".") || text.contains("e") || text.hasSuffix("pi") ? "Float" : "Integer")
        case .builtin:
            switch text {
            case "nil": return .instance("Nil")
            case "true": return .instance("True")
            case "false": return .instance("False")
            case "inf", "pi": return .instance("Float")
            default: return .instance("Environment")
            }
        case .closeBrace: return .instance("Function")
        case .closeBracket:
            // `[1, 2]` is an Array; `a[0]` is anything.
            guard let open = matching(tokens, close: i, open: .openBracket, closeKind: .closeBracket),
                  let prev = tokens[..<open].last(where: { $0.kind != .whitespace }) else { return .instance("Array") }
            return [.identifier, .className, .closeParen, .closeBracket, .environment].contains(prev.kind) ? .unknown : .instance("Array")
        case .closeParen:
            // `SinOsc.ar(…)`, `Pbind(…)`: an instance of the class.
            guard let open = matching(tokens, close: i, open: .openParen, closeKind: .closeParen) else { return .unknown }
            let prev = tokens[..<open].filter { $0.kind != .whitespace }.suffix(3)
            let words = prev.map { String(decoding: u[$0.range], as: UTF16.self) }
            if let last = prev.last, last.kind == .className { return .instance(words.last!) }
            if prev.count == 3, prev.first!.kind == .className, words[1] == ".",
               ["new", "ar", "kr", "ir", "newClear", "with", "fill", "series"].contains(words[2]) {
                return .instance(words[0])
            }
            return .unknown
        default: return .unknown
        }
    }

    static func matching(_ tokens: [SCToken], close: Int, open: SCTokenKind, closeKind: SCTokenKind) -> Int? {
        var depth = 0
        var k = close
        while k >= 0 {
            if tokens[k].kind == closeKind { depth += 1 }
            else if tokens[k].kind == open { depth -= 1; if depth == 0 { return k } }
            k -= 1
        }
        return nil
    }

    // MARK: Signature help

    public struct Signature: Sendable, Hashable {
        public var method: SCClassLibrary.Method
        /// The argument the caret is in, if the call has that many.
        public var activeArgument: Int?

        public var display: String {
            let head = method.owner + (method.isClassMethod ? "." : ":") + method.name
            return head + "(" + method.argumentList(highlighting: activeArgument) + ")"
        }
    }

    /// The call the caret is inside: `SinOsc.ar(440, |` → `SinOsc.ar`, phase.
    public static func signature(_ text: String, caret: Int, library: SCClassLibrary) -> Signature? {
        let u = Array(text.utf16)
        let caret = min(max(caret, 0), u.count)
        let tokens = SCLexer.tokenize(Array(u[..<caret])).filter { $0.kind != .whitespace && $0.kind != .comment }
        var depth = 0
        var commas = 0
        var keyword: String?
        var k = tokens.count - 1
        while k >= 0 {
            let t = tokens[k]
            switch t.kind {
            case .closeParen, .closeBracket, .closeBrace: depth += 1
            case .openBracket, .openBrace:
                // Inside `[…]` or `{…}` passed as an argument: what counts
                // is which argument that literal is.
                if depth == 0 { commas = 0; keyword = nil } else { depth -= 1 }
            case .openParen:
                if depth > 0 { depth -= 1; break }
                return resolve(call: k, tokens: tokens, u: u, library: library, commas: commas, keyword: keyword)
            case .punctuation where depth == 0:
                let s = String(decoding: u[t.range], as: UTF16.self)
                if s == "," { commas += 1 }
                if s == ";" { return nil }
                if s == ":", commas == 0, keyword == nil, k > 0, tokens[k - 1].kind == .identifier {
                    keyword = String(decoding: u[tokens[k - 1].range], as: UTF16.self)
                }
            default: break
            }
            k -= 1
        }
        return nil
    }

    static func resolve(call open: Int, tokens: [SCToken], u: [UInt16], library: SCClassLibrary,
                        commas: Int, keyword: String?) -> Signature? {
        guard open > 0 else { return nil }
        func word(_ i: Int) -> String { String(decoding: u[tokens[i].range], as: UTF16.self) }
        let callee = tokens[open - 1]
        var method: SCClassLibrary.Method?
        if callee.kind == .className {
            method = library.method("new", of: word(open - 1), classSide: true)
        } else if callee.kind == .identifier, open >= 2, word(open - 2) == "." {
            let name = word(open - 1)
            let dot = tokens[open - 2].range.lowerBound
            let all = SCLexer.tokenize(Array(u[..<dot]))
            switch receiver(before: dot, tokens: all, u: u) {
            case .classObject(let c): method = library.method(name, of: c, classSide: true)
            case .instance(let c): method = library.method(name, of: c, classSide: false)
            case .unknown:
                method = library.implementors[name]?.sorted().first.flatMap { library.classes[$0]?.instanceMethods[name] }
            }
        }
        guard let method else { return nil }
        var active: Int? = commas < method.arguments.count ? commas : nil
        if let keyword { active = method.arguments.firstIndex { $0.name == keyword } }
        return Signature(method: method, activeArgument: active)
    }

    // MARK: Help

    /// What ⌘D looks up: the word at the caret, and for a method of a
    /// class the text shows, that class and the method's anchor.
    public struct HelpTopic: Sendable, Hashable {
        public var word: String
        public var className: String?
        /// `*ar` for a class method, `-range` for an instance method.
        public var anchor: String?
    }

    public static func helpTopic(_ text: String, caret: Int, library: SCClassLibrary) -> HelpTopic? {
        let u = Array(text.utf16)
        let caret = min(max(caret, 0), u.count)
        var s = caret, e = caret
        while s > 0, SCLexer.isIdentPart(u[s - 1]) { s -= 1 }
        while e < u.count, SCLexer.isIdentPart(u[e]) { e += 1 }
        guard s < e else { return nil }
        let word = String(decoding: u[s..<e], as: UTF16.self)
        guard let f = word.utf16.first, SCLexer.isIdentStart(f) else { return nil }
        if SCLexer.isUpper(f) { return HelpTopic(word: word) }
        if s > 0, u[s - 1] == 0x2E {
            let tokens = SCLexer.tokenize(Array(u[..<(s - 1)]))
            switch receiver(before: s - 1, tokens: tokens, u: u) {
            case .classObject(let c):
                if let m = library.method(word, of: c, classSide: true) { return HelpTopic(word: word, className: m.owner, anchor: "*" + word) }
            case .instance(let c):
                if let m = library.method(word, of: c, classSide: false) { return HelpTopic(word: word, className: m.owner, anchor: "-" + word) }
            case .unknown: break
            }
        }
        return HelpTopic(word: word)
    }
}

/// Splits sclang's output into what the post window shows and the replies
/// Pondside asked for. A reply is one line, `RS PONDSIDE <id> <payload>`,
/// where RS is the record separator (0x1E), which no post contains.
public struct SCPostStream: Sendable {
    public enum Piece: Equatable, Sendable {
        case post(String)
        case reply(id: Int, payload: String)
    }

    public static let marker = "\u{1E}PONDSIDE "
    private var pending = ""

    public init() {}

    /// Feeds a chunk; returns posts as soon as they arrive (a line need not
    /// be finished) and replies once their line is complete.
    public mutating func feed(_ chunk: String) -> [Piece] {
        pending += chunk
        var out: [Piece] = []
        var post = ""
        while let nl = pending.firstIndex(of: "\n") {
            let line = String(pending[..<nl])
            pending = String(pending[pending.index(after: nl)...])
            if let r = line.firstRange(of: Self.marker) {
                post += line[..<r.lowerBound]
                let rest = line[r.upperBound...]
                let space = rest.firstIndex(of: " ") ?? rest.endIndex
                if let id = Int(rest[..<space]) {
                    if !post.isEmpty { out.append(.post(post)); post = "" }
                    out.append(.reply(id: id, payload: space < rest.endIndex ? String(rest[rest.index(after: space)...]) : ""))
                    continue
                }
                post += line[r.lowerBound...] + "\n"
            } else {
                post += line + "\n"
            }
        }
        // A partial line goes out now unless it could be a reply.
        if !pending.isEmpty, !pending.contains("\u{1E}") {
            post += pending
            pending = ""
        }
        if !post.isEmpty { out.append(.post(post)) }
        return out
    }
}

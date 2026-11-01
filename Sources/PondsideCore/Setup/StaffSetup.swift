/// The staves of a score as Score Setup shows them: each `\new Staff` with
/// its name, short name, MIDI sound and starting clef, and the minimal
/// edits that change them.
///
/// Names live in the staff's `\with` block (or a `\set Staff.instrumentName`
/// at the start of its music, which is changed where it is). The clef is
/// the first `\clef` before the staff's first note, following variables
/// (`\new Staff \violinI`) into their definitions in any file; with none,
/// a new clef goes into `\with`, where LilyPond takes it as the staff's
/// initial clef. Nothing is reprinted: each change replaces a string,
/// adds a statement or removes one.
public struct StaffSetup: Sendable {
    /// A value written in the source.
    public struct Field: Sendable, Hashable {
        /// The text it shows: a string's contents, or a markup's words.
        public var value: String
        /// Whether Pondside can rewrite it (a plain string, not `\markup`).
        public var editable: Bool
        public var file: Int
        /// The value's bytes (the string literal, quotes included).
        public var valueRange: Range<Int>
        /// The whole statement, key to value.
        public var statement: Range<Int>
    }

    public struct Staff: Sendable, Hashable, Identifiable {
        public var id: Int { index }
        public var index: Int
        public var file: Int
        /// Staff, RhythmicStaff, TabStaff, DrumStaff…
        public var context: String
        /// `\new Staff = "up"`.
        public var name: String?
        public var instrumentName: Field?
        public var shortInstrumentName: Field?
        public var midiInstrument: Field?
        /// The clef the staff starts in, as written; nil means LilyPond's treble.
        public var clef: Field?
        /// The line of `\new`, 1-based, for "Show in Source".
        public var line: Int
        /// The names of the groups around it (`\new PianoStaff \with { instrumentName = "Electronics" } <<`).
        public var groupNames: [String] = []
        /// Offset of `\new` in its file.
        public var offset: Int
        var withBlock: (open: Int, close: Int)?
        /// Where a new `\with` goes: after the context name or its `= "id"`.
        var withAnchor: Int
        var withClef: Field?

        public static func == (a: Staff, b: Staff) -> Bool {
            a.index == b.index && a.file == b.file && a.offset == b.offset && a.instrumentName == b.instrumentName
                && a.shortInstrumentName == b.shortInstrumentName && a.midiInstrument == b.midiInstrument && a.clef == b.clef
        }

        public func hash(into h: inout Hasher) {
            h.combine(file)
            h.combine(offset)
        }

        /// The instrument the staff stands for: its explicit MIDI sound's,
        /// else the one its name means.
        public var instrument: Instrument? {
            if let name = instrumentName?.value, let hit = Instrument.matching(name: name) { return hit }
            return midiInstrument.flatMap { Instrument.playing(midi: $0.value) }
        }

        /// An electronics part: its name, id or group says so. Its symbols are
        /// the patch's, not a performer's.
        public var isElectronics: Bool {
            let names = [instrumentName?.value, name].compactMap { $0 } + groupNames
            return names.contains { n in
                Instrument.matching(name: n)?.family == .electronics || n.lowercased().hasPrefix("elec") || n.lowercased().contains("tape")
            }
        }

        /// What the staff is shown as when it has no name.
        public var label: String {
            if let n = instrumentName?.value, !n.isEmpty { return n }
            if let name { return "\(context) “\(name)”" }
            return "\(context) \(index + 1)"
        }
    }

    /// What to change on one staff; nil leaves a field as it is, "" removes it.
    public struct Change: Sendable, Hashable {
        public var instrumentName: String?
        public var shortInstrumentName: String?
        public var midiInstrument: String?
        public var clef: String?

        public init(instrumentName: String? = nil, shortInstrumentName: String? = nil, midiInstrument: String? = nil,
                    clef: String? = nil) {
            self.instrumentName = instrumentName
            self.shortInstrumentName = shortInstrumentName
            self.midiInstrument = midiInstrument
            self.clef = clef
        }

        /// Everything an instrument sets: its names, sound and clef.
        public init(instrument: Instrument) {
            self.init(instrumentName: instrument.name, shortInstrumentName: instrument.shortName,
                      midiInstrument: instrument.midi ?? "", clef: instrument.clef)
        }
    }

    public static let staffContexts: Set<String> = ["Staff", "RhythmicStaff", "TabStaff", "DrumStaff", "VaticanaStaff",
                                                    "MensuralStaff", "PetrucciStaff", "KievanStaff", "GregorianTranscriptionStaff"]

    public let texts: [String]
    public let staves: [Staff]

    /// `files[0]` is the root; the others are the files it includes.
    public init(files: [String]) {
        texts = files
        let scanned = files.map { SetupScan($0) }
        var definitions: [String: (file: Int, leaf: Int)] = [:]
        for (f, s) in scanned.enumerated() {
            for (name, leaf) in s.assignments where definitions[name] == nil { definitions[name] = (f, leaf) }
        }
        var staves: [Staff] = []
        for (f, s) in scanned.enumerated() {
            let groups = s.groupNames()
            for staff in s.staves(file: f) {
                var staff = staff
                staff.index = staves.count
                staff.groupNames = groups[staff.offset] ?? []
                var finder = MusicScan(files: scanned, definitions: definitions)
                if let start = s.musicStart[staff.offset] {
                    let found = finder.scan(file: f, from: start)
                    staff.clef = found.clef ?? staff.withClef
                    if staff.instrumentName == nil { staff.instrumentName = found.instrumentName }
                    if staff.shortInstrumentName == nil { staff.shortInstrumentName = found.shortInstrumentName }
                } else {
                    staff.clef = staff.withClef
                }
                staves.append(staff)
            }
        }
        self.staves = staves
    }

    // MARK: Writing

    /// The edits for `change` on staff `index`, by file index, each list
    /// against that file's current text.
    public func edits(staff index: Int, _ change: Change) -> [Int: [TextEdit]] {
        guard staves.indices.contains(index) else { return [:] }
        let staff = staves[index]
        var result: [Int: [TextEdit]] = [:]
        var additions: [String] = []   // statements for the \with block

        func set(_ field: Field?, key: String, to value: String?) {
            guard let value else { return }
            if let field {
                if value.isEmpty {
                    result[field.file, default: []].append(removal(of: field.statement, in: field.file))
                } else if field.value != value || !field.editable {
                    result[field.file, default: []].append(TextEdit(field.valueRange, Self.quoted(value)))
                }
            } else if !value.isEmpty {
                additions.append("\(key) = \(Self.quoted(value))")
            }
        }
        set(staff.instrumentName, key: "instrumentName", to: change.instrumentName)
        set(staff.shortInstrumentName, key: "shortInstrumentName", to: change.shortInstrumentName)
        set(staff.midiInstrument, key: "midiInstrument", to: change.midiInstrument)

        if let clef = change.clef {
            if let field = staff.clef {
                if clef.isEmpty {
                    if field == staff.withClef { result[field.file, default: []].append(removal(of: field.statement, in: field.file)) }
                } else if field.value != clef {
                    result[field.file, default: []].append(TextEdit(field.valueRange, Self.clefArgument(clef)))
                }
            } else if !clef.isEmpty, clef != "treble" {
                additions.append("\\clef \(Self.clefArgument(clef))")
            }
        }

        if !additions.isEmpty {
            result[staff.file, default: []].append(insertion(of: additions, into: staff))
        }
        return result.mapValues { $0.sorted { $0.range.lowerBound < $1.range.lowerBound } }
    }

    /// `"text"`, escaped as LilyPond reads strings.
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for c in text {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += " "
            default: out.append(c)
            }
        }
        return out + "\""
    }

    /// A clef name as `\clef` takes it: bare when it is one word, else quoted.
    static func clefArgument(_ clef: String) -> String {
        clef.allSatisfy(\.isLetter) ? clef : quoted(clef)
    }

    private func bytes(_ file: Int) -> [UInt8] { Array(texts[file].utf8) }

    /// The statement's line when nothing else is on it, else the statement
    /// and the space before it.
    private func removal(of range: Range<Int>, in file: Int) -> TextEdit {
        let b = bytes(file)
        var start = range.lowerBound
        while start > 0, b[start - 1] == 0x20 || b[start - 1] == 0x09 { start -= 1 }
        var end = range.upperBound
        while end < b.count, b[end] == 0x20 || b[end] == 0x09 { end += 1 }
        if (start == 0 || b[start - 1] == 0x0A), end < b.count, b[end] == 0x0A { return TextEdit(start..<(end + 1), "") }
        // The statement and the space before it: `\with { a = 1 b = 2 }` → `\with { a = 1 }`.
        return TextEdit(start..<range.upperBound, "")
    }

    private func insertion(of statements: [String], into staff: Staff) -> TextEdit {
        let b = bytes(staff.file)
        guard let block = staff.withBlock else {
            return .insert(" \\with { " + statements.joined(separator: " ") + " }", at: staff.withAnchor)
        }
        let multiline = b[block.open..<block.close].contains(0x0A)
        if multiline {
            // After the last statement, indented like the block's lines.
            var at = block.close
            while at > block.open + 1, [0x20, 0x09, 0x0A].contains(b[at - 1]) { at -= 1 }
            var lineStart = at
            while lineStart > 0, b[lineStart - 1] != 0x0A { lineStart -= 1 }
            var indentEnd = lineStart
            while indentEnd < at, b[indentEnd] == 0x20 || b[indentEnd] == 0x09 { indentEnd += 1 }
            var indent = String(decoding: b[lineStart..<indentEnd], as: UTF8.self)
            if at == block.open + 1 { indent += "  " }
            return .insert(statements.map { "\n" + indent + $0 }.joined(), at: at)
        }
        // `\with { a = 1 }` → `\with { a = 1 b = 2 }`.
        var at = block.close
        while at > block.open + 1, b[at - 1] == 0x20 || b[at - 1] == 0x09 { at -= 1 }
        let trail = at == block.close ? " " : ""
        return .insert(" " + statements.joined(separator: " ") + trail, at: at)
    }
}

// MARK: - Scanning

/// One file's significant tokens, with what Score Setup needs to find.
struct SetupScan {
    struct Leaf {
        var kind: SyntaxKind
        var range: Range<Int>
        var text: String
    }

    let tree: SyntaxTree
    let leaves: [Leaf]
    let eventStarts: Set<Int>
    /// Top-level `name = …`: the leaf where the value starts.
    let assignments: [String: Int]
    /// For each staff's `\new` offset, the leaf its music starts at.
    var musicStart: [Int: Int] = [:]

    init(_ text: String) {
        tree = SyntaxTree(text)
        var leaves: [Leaf] = []
        let tree = self.tree
        tree.root.forEachLeaf { leaf in
            if !leaf.kind.isTrivia { leaves.append(Leaf(kind: leaf.kind, range: leaf.range, text: tree.string(leaf.range))) }
        }
        self.leaves = leaves
        eventStarts = Set(tree.events.map(\.range.lowerBound))
        var assignments: [String: Int] = [:]
        var depth = 0
        for (i, leaf) in leaves.enumerated() {
            switch leaf.kind {
            case .openBrace, .openSimultaneous: depth += 1
            case .closeBrace, .closeSimultaneous: depth -= 1
            case .word where depth == 0:
                if i + 2 < leaves.count, leaves[i + 1].kind == .equals, assignments[leaf.text] == nil {
                    assignments[leaf.text] = i + 2
                }
            default: break
            }
        }
        self.assignments = assignments
        musicStart = [:]
        for staff in staffHeads() { musicStart[staff.offset] = staff.music }
    }

    /// For each staff's `\new` offset, the instrument names of the groups
    /// (`\new PianoStaff \with { instrumentName = … } << … >>`) around it.
    func groupNames() -> [Int: [String]] {
        var result: [Int: [String]] = [:]
        var stack: [String?] = []
        var i = 0
        while i < leaves.count {
            let leaf = leaves[i]
            if leaf.kind == .command, leaf.text == "\\new" || leaf.text == "\\context", i + 1 < leaves.count {
                let context = leaves[i + 1].text
                if StaffSetup.staffContexts.contains(context) {
                    result[leaf.range.lowerBound] = stack.compactMap { $0 }
                } else if context.hasSuffix("Staff") || context.hasSuffix("Group") {
                    // A group: its name, then its << … >>.
                    var j = i + 2
                    if j + 1 < leaves.count, leaves[j].kind == .equals, leaves[j + 1].kind == .string { j += 2 }
                    var name: String?
                    if j + 1 < leaves.count, leaves[j].text == "\\with", leaves[j + 1].kind == .openBrace, let close = matching(from: j + 1) {
                        for k in (j + 1)..<close where leaves[k].text == "instrumentName" && k + 2 < close
                            && leaves[k + 1].kind == .equals && leaves[k + 2].kind == .string {
                            name = Self.unquote(leaves[k + 2].text)
                        }
                        j = close + 1
                    }
                    if j < leaves.count, leaves[j].kind == .openSimultaneous {
                        stack.append(name)
                        i = j + 1
                        continue
                    }
                }
            } else if leaf.kind == .openSimultaneous {
                stack.append(nil)
            } else if leaf.kind == .closeSimultaneous {
                _ = stack.popLast()
            }
            i += 1
        }
        return result
    }

    struct Head {
        var offset: Int
        var newLeaf: Int
        var context: String
        var name: String?
        var withBlock: (open: Int, close: Int, openLeaf: Int, closeLeaf: Int)?
        var anchor: Int
        var music: Int
    }

    func staffHeads() -> [Head] {
        var heads: [Head] = []
        var i = 0
        while i < leaves.count {
            defer { i += 1 }
            guard leaves[i].kind == .command, leaves[i].text == "\\new" || leaves[i].text == "\\context",
                  i + 1 < leaves.count, StaffSetup.staffContexts.contains(leaves[i + 1].text) else { continue }
            var head = Head(offset: leaves[i].range.lowerBound, newLeaf: i, context: leaves[i + 1].text, name: nil,
                            withBlock: nil, anchor: leaves[i + 1].range.upperBound, music: i + 2)
            var j = i + 2
            if j + 1 < leaves.count, leaves[j].kind == .equals, leaves[j + 1].kind == .string {
                head.name = Self.unquote(leaves[j + 1].text)
                head.anchor = leaves[j + 1].range.upperBound
                j += 2
            }
            if j + 1 < leaves.count, leaves[j].kind == .command, leaves[j].text == "\\with", leaves[j + 1].kind == .openBrace,
               let close = matching(from: j + 1) {
                head.withBlock = (leaves[j + 1].range.lowerBound, leaves[close].range.lowerBound, j + 1, close)
                j = close + 1
            }
            head.music = j
            heads.append(head)
        }
        return heads
    }

    func staves(file: Int) -> [StaffSetup.Staff] {
        staffHeads().map { head in
            var staff = StaffSetup.Staff(index: 0, file: file, context: head.context, name: head.name, line: line(of: head.offset),
                                         offset: head.offset, withBlock: head.withBlock.map { ($0.open, $0.close) },
                                         withAnchor: head.anchor)
            if let block = head.withBlock {
                var k = block.openLeaf + 1
                while k < block.closeLeaf {
                    let leaf = leaves[k]
                    if leaf.kind == .word, ["instrumentName", "shortInstrumentName", "midiInstrument"].contains(leaf.text),
                       k + 2 <= block.closeLeaf, leaves[k + 1].kind == .equals,
                       let field = value(at: k + 2, limit: block.closeLeaf, file: file, statementStart: leaf.range.lowerBound) {
                        switch leaf.text {
                        case "instrumentName": staff.instrumentName = field.field
                        case "shortInstrumentName": staff.shortInstrumentName = field.field
                        default: staff.midiInstrument = field.field
                        }
                        k = field.next
                        continue
                    }
                    if leaf.kind == .command, leaf.text == "\\clef", k + 1 < block.closeLeaf, let clef = clef(at: k, file: file) {
                        staff.withClef = clef
                        k += 2
                        continue
                    }
                    k += 1
                }
            }
            return staff
        }
    }

    /// The value starting at leaf `k`: a string, or a `\markup …` (shown, not rewritten).
    func value(at k: Int, limit: Int, file: Int, statementStart: Int) -> (field: StaffSetup.Field, next: Int)? {
        guard k < limit else { return nil }
        let leaf = leaves[k]
        if leaf.kind == .string {
            return (StaffSetup.Field(value: Self.unquote(leaf.text), editable: true, file: file, valueRange: leaf.range,
                                     statement: statementStart..<leaf.range.upperBound), k + 1)
        }
        // `\markup { … }`, `\markup \bold "x"`, `#"x"`: up to the next statement.
        var end = k
        var words: [String] = []
        var depth = 0
        while end < limit {
            let l = leaves[end]
            if depth == 0, end > k, l.kind == .word, end + 1 < limit, leaves[end + 1].kind == .equals { break }
            if depth == 0, end > k, l.kind == .command, l.text == "\\clef" || l.text == "\\consists" || l.text == "\\remove" || l.text == "\\override" { break }
            if l.kind == .openBrace { depth += 1 }
            if l.kind == .closeBrace { depth -= 1; if depth == 0 { end += 1; break } }
            if l.kind == .string { words.append(Self.unquote(l.text)) }
            if l.kind == .markupWord || l.kind == .word { words.append(l.text) }
            if l.kind == .schemeText, l.text.hasPrefix("\"") { words.append(Self.unquote(l.text)) }
            end += 1
            if depth == 0, l.kind == .string || l.kind == .schemeText { break }
        }
        guard end > k else { return nil }
        let range = leaf.range.lowerBound..<leaves[end - 1].range.upperBound
        return (StaffSetup.Field(value: words.joined(separator: " "), editable: false, file: file, valueRange: range,
                                 statement: statementStart..<range.upperBound), end)
    }

    func clef(at k: Int, file: Int) -> StaffSetup.Field? {
        guard k + 1 < leaves.count else { return nil }
        let arg = leaves[k + 1]
        guard arg.kind == .string || arg.kind == .word || arg.kind == .pitchName || arg.kind == .markupWord else { return nil }
        let name = arg.kind == .string ? Self.unquote(arg.text) : arg.text
        return StaffSetup.Field(value: name, editable: true, file: file, valueRange: arg.range,
                                statement: leaves[k].range.lowerBound..<arg.range.upperBound)
    }

    func matching(from open: Int) -> Int? {
        var depth = 0
        for k in open..<leaves.count {
            if leaves[k].kind == .openBrace { depth += 1 }
            if leaves[k].kind == .closeBrace { depth -= 1; if depth == 0 { return k } }
        }
        return nil
    }

    func line(of offset: Int) -> Int {
        var line = 1
        for b in tree.bytes[0..<min(offset, tree.bytes.count)] where b == 0x0A { line += 1 }
        return line
    }

    static func unquote(_ s: String) -> String {
        var t = Substring(s)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = t.dropFirst().dropLast() }
        var out = ""
        var escaped = false
        for c in t {
            if escaped {
                out.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}

/// Walks a staff's music up to its first note, through variables, for the
/// clef it starts in and any `\set Staff.instrumentName`.
private struct MusicScan {
    let files: [SetupScan]
    let definitions: [String: (file: Int, leaf: Int)]
    var clef: StaffSetup.Field?
    var instrumentName: StaffSetup.Field?
    var shortInstrumentName: StaffSetup.Field?
    var visited: Set<String> = []

    init(files: [SetupScan], definitions: [String: (file: Int, leaf: Int)]) {
        self.files = files
        self.definitions = definitions
    }

    enum Stop { case reachedNote, endedExpression, foundClef }

    struct Found {
        var clef: StaffSetup.Field?
        var instrumentName: StaffSetup.Field?
        var shortInstrumentName: StaffSetup.Field?
    }

    mutating func scan(file: Int, from start: Int) -> Found {
        _ = walk(file: file, from: start, depth: 0)
        return Found(clef: clef, instrumentName: instrumentName, shortInstrumentName: shortInstrumentName)
    }

    private mutating func walk(file f: Int, from start: Int, depth: Int) -> Stop {
        let s = files[f]
        var nesting = 0
        var opened = false
        var k = start
        while k < s.leaves.count {
            let leaf = s.leaves[k]
            switch leaf.kind {
            case .openBrace, .openSimultaneous:
                nesting += 1
                opened = true
            case .closeBrace, .closeSimultaneous:
                nesting -= 1
                if nesting <= 0 { return .endedExpression }
            case .command:
                if leaf.text == "\\clef", let c = s.clef(at: k, file: f) {
                    clef = c
                    return .foundClef
                }
                if leaf.text == "\\new" || leaf.text == "\\context", k + 1 < s.leaves.count,
                   StaffSetup.staffContexts.contains(s.leaves[k + 1].text) {
                    return .endedExpression
                }
                if leaf.text == "\\set" {
                    // `Staff.instrumentName` is lexed as words and dots.
                    var e = k + 1
                    var path = ""
                    while e < s.leaves.count, e < k + 5, s.leaves[e].kind != .equals { path += s.leaves[e].text; e += 1 }
                    if ["Staff.instrumentName", "Staff.shortInstrumentName", "instrumentName", "shortInstrumentName"].contains(path),
                       e < s.leaves.count, s.leaves[e].kind == .equals,
                       let v = s.value(at: e + 1, limit: s.leaves.count, file: f, statementStart: leaf.range.lowerBound) {
                        if path.hasSuffix("shortInstrumentName") {
                            if shortInstrumentName == nil { shortInstrumentName = v.field }
                        } else if instrumentName == nil {
                            instrumentName = v.field
                        }
                        k = v.next
                        continue
                    }
                }
                let name = String(leaf.text.dropFirst())
                if depth < 6, let def = definitions[name], !visited.contains(name) {
                    visited.insert(name)
                    let stop = walk(file: def.file, from: def.leaf, depth: depth + 1)
                    if stop != .endedExpression { return stop }
                    // The whole music was that variable.
                    if !opened { return .endedExpression }
                }
            default:
                if s.eventStarts.contains(leaf.range.lowerBound) { return .reachedNote }
            }
            k += 1
        }
        return .endedExpression
    }
}

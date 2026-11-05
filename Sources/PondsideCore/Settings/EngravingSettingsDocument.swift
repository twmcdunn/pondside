/// The engraving settings of one score, read from its root file, and the
/// minimal edits that change them.
///
/// Statements are looked for where a score keeps them: the top-level
/// `\paper` and `\header`, and the `\layout` of the first `\score` (else a
/// top-level `\layout`), with `\context { \Score }` and `\context { \Staff }`
/// inside it. A change replaces the statement's own bytes, adds one line at
/// the end of its block, or removes its line; a missing block is added in
/// the place LilyPond reads it. Other files of the score (e.g. a part
/// converted by musicxml2ly) are only read: what they set is reported, and
/// outvoted by an explicit statement in the root when the dialog changes it.
public struct EngravingSettingsDocument: Sendable {
    public struct Found: Sendable, Hashable {
        public var value: EngravingValue
        /// The root file's own statement, in the setting's block.
        public var inRoot: Bool
        /// Where something else sets it: a file label and 1-based line.
        public var elsewhere: [Where]
        public init(value: EngravingValue, inRoot: Bool, elsewhere: [Where]) {
            self.value = value; self.inRoot = inRoot; self.elsewhere = elsewhere
        }
    }

    public struct Where: Sendable, Hashable {
        public var file: String
        public var line: Int
        public var statement: String
    }

    public let text: String
    private let bytes: [UInt8]
    private let blocks: [Block]
    private let others: [(file: String, text: String)]
    /// The other files' statement lines, trimmed and without comments, read
    /// once: every setting searches them, and re-splitting each file per
    /// setting made reading the panel's values take a third of a second.
    private let otherLines: [(file: String, line: Int, text: String)]
    /// Each word of those lines to the lines holding it: a key can only be
    /// on a line that has its first word.
    private let otherWords: [Substring: [Int]]

    public init(root text: String, others: [(file: String, text: String)] = []) {
        self.text = text
        bytes = Array(text.utf8)
        blocks = Self.findBlocks(in: SyntaxTree(text))
        self.others = others
        var lines: [(file: String, line: Int, text: String)] = []
        for other in others {
            var line = 0
            for raw in other.text.split(separator: "\n", omittingEmptySubsequences: false) {
                line += 1
                var text = raw.trimmedSpaces
                if let comment = text.firstIndex(of: "%"), !text.hasPrefix("#(") { text = String(text[..<comment]).trimmedSpaces }
                if !text.isEmpty { lines.append((other.file, line, text)) }
            }
        }
        otherLines = lines
        var words: [Substring: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            for word in Set(Self.words(line.text)) { words[word, default: []].append(index) }
        }
        otherWords = words
    }

    /// Words as `starts(_:with:)` delimits a key: split at blanks, `=` and
    /// braces, and without the `)` that can close a Scheme key.
    private static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" || $0 == "{" || $0 == "}" })
            .map { word in
                var word = word[...]
                while word.last == ")" { word = word.dropLast() }
                return word
            }
            .filter { !$0.isEmpty }
    }

    // MARK: Reading

    public func value(of setting: EngravingSetting) -> Found {
        let mine = rootStatements(for: setting)
        let elsewhere = elsewhereStatements(for: setting)
        if !mine.isEmpty, let v = setting.parse(dictionary(mine, extraKeys: setting.keys + setting.readKeys)) {
            return Found(value: v, inRoot: true, elsewhere: elsewhere)
        }
        // The last statement elsewhere is the one LilyPond would read last.
        var others: [String: String] = [:]
        for w in elsewhere {
            if let key = (setting.keys + setting.readKeys).first(where: { Self.starts(w.statement, with: $0) }) { others[key] = w.statement }
        }
        let v = others.isEmpty ? nil : setting.parse(others)
        return Found(value: v ?? setting.defaultValue, inRoot: false, elsewhere: elsewhere)
    }

    public var values: [String: Found] {
        Dictionary(uniqueKeysWithValues: EngravingSetting.all.map { ($0.id, value(of: $0)) })
    }

    // MARK: Header fields

    /// A top-level `\header` field, such as the cover page reads.
    public struct HeaderField: Sendable, Hashable {
        public var value: String
        /// A plain string Pondside can rewrite; false for `\markup` or Scheme.
        public var editable: Bool
        /// Where another file sets it, when the root does not.
        public var elsewhere: Where?
    }

    public func headerField(_ key: String) -> HeaderField {
        let setting = EngravingSetting.headerText(key)
        let found = value(of: setting)
        let raw = found.value.choice ?? ""
        if raw.hasPrefix(EngravingSetting.rawMarker) {
            return HeaderField(value: String(raw.dropFirst()), editable: false, elsewhere: found.inRoot ? nil : found.elsewhere.last)
        }
        return HeaderField(value: raw, editable: true, elsewhere: found.inRoot ? nil : found.elsewhere.last)
    }

    /// Sets a `\header` field to a string; an empty one removes it.
    public func edits(headerField key: String, to value: String) -> [TextEdit] {
        edits(setting: EngravingSetting.headerText(key), to: .choice(value))
    }

    // MARK: Writing

    /// The edits that make `setting` read `value`. A default is written out
    /// only when another file sets something else, so the root's word wins.
    public func edits(setting: EngravingSetting, to value: EngravingValue) -> [TextEdit] {
        let explicit = !elsewhereStatements(for: setting).isEmpty
        let wanted = setting.statements(for: value, explicit: explicit)
        let block = target(for: setting.location)
        // The root's own statement is changed where the user put it.
        let existing = rootStatements(for: setting).filter { s in setting.keys.contains { Self.starts(s.text, with: $0) } }

        if let first = existing.first {
            var edits: [TextEdit] = []
            if wanted.isEmpty {
                edits.append(TextEdit(lineRange(of: first.range), ""))
            } else {
                let indent = indentation(at: first.range.lowerBound)
                edits.append(TextEdit(first.range, wanted.joined(separator: "\n" + indent)))
            }
            for extra in existing.dropFirst() { edits.append(TextEdit(lineRange(of: extra.range), "")) }
            return edits
        }
        guard !wanted.isEmpty else { return [] }
        if let block { return [insertion(of: wanted, into: block)] }
        return [creation(of: wanted, at: setting.location)]
    }

    /// One edit, against this text, for several changes made together.
    public func edits(for changes: [(EngravingSetting, EngravingValue)]) -> [TextEdit] {
        var current = self
        for (setting, value) in changes {
            let step = current.edits(setting: setting, to: value)
            guard !step.isEmpty else { continue }
            current = EngravingSettingsDocument(root: step.apply(to: current.text), others: others)
        }
        return Self.span(from: bytes, to: Array(current.text.utf8))
    }

    /// The smallest single replacement turning `old` into `new`.
    public static func span(from old: [UInt8], to new: [UInt8]) -> [TextEdit] {
        guard old != new else { return [] }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Keep the edit on character boundaries.
        // (At the very end of either text there is no byte to look at.)
        func continues(_ bytes: [UInt8], _ i: Int) -> Bool { i < bytes.count && bytes[i] & 0xC0 == 0x80 }
        while prefix > 0, continues(old, prefix) || continues(new, prefix) { prefix -= 1 }
        while suffix > 0, continues(old, old.count - suffix) || continues(new, new.count - suffix) { suffix -= 1 }
        let replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF8.self)
        return [TextEdit(prefix..<(old.count - suffix), replacement)]
    }

    // MARK: Blocks

    struct Block: Sendable {
        var name: String          // paper, header, layout, score, context, …
        var context: String?      // Score / Staff, for a \context block
        var command: Range<Int>   // the \name token
        var open: Int             // offset of `{`
        var close: Int            // offset of `}`
        var depth: Int            // 0 at top level
        var parent: Int?
        var body: Range<Int> { (open + 1)..<close }
    }

    private static let blockNames: Set<String> = ["paper", "header", "layout", "score", "context", "book", "bookpart",
                                                  "midi", "with"]

    /// Whether `text` asks for MIDI itself: a `\midi` block inside a
    /// `\score` (a top-level `\midi` only sets defaults).
    public static func writesMIDI(_ text: String) -> Bool {
        guard text.contains("\\midi") else { return false }
        let blocks = findBlocks(in: SyntaxTree(text))
        return blocks.contains { block in
            guard block.name == "midi" else { return false }
            var parent = block.parent
            while let p = parent {
                if blocks[p].name == "score" { return true }
                parent = blocks[p].parent
            }
            return false
        }
    }

    static func findBlocks(in tree: SyntaxTree) -> [Block] {
        var leaves: [SyntaxNode] = []
        tree.root.forEachLeaf { leaf in
            if leaf.kind != .whitespace, leaf.kind != .lineComment, leaf.kind != .blockComment { leaves.append(leaf) }
        }
        var result: [Block] = []
        var stack: [Int?] = []   // block index for each open brace, nil for music braces
        for (i, leaf) in leaves.enumerated() {
            switch leaf.kind {
            case .openBrace:
                let parent = stack.last { $0 != nil } ?? nil
                if i > 0, leaves[i - 1].kind == .command {
                    let name = String(tree.string(leaves[i - 1].range).dropFirst())
                    if blockNames.contains(name) {
                        result.append(Block(name: name, context: nil, command: leaves[i - 1].range, open: leaf.range.lowerBound,
                                            close: leaf.range.lowerBound, depth: stack.count, parent: parent))
                        stack.append(result.count - 1)
                        // `\context { \Score …`: the context it defines.
                        if name == "context", let next = leaves[safe: i + 1], next.kind == .command {
                            result[result.count - 1].context = String(tree.string(next.range).dropFirst())
                        }
                        continue
                    }
                }
                stack.append(nil)
            case .closeBrace:
                if let top = stack.popLast(), let index = top { result[index].close = leaf.range.lowerBound }
            default:
                break
            }
        }
        return result.filter { $0.close > $0.open }
    }

    /// The block a location's statements belong in, if the root has it.
    private func target(for location: EngravingSetting.Location) -> Block? {
        switch location {
        case .paper: return blocks.first { $0.name == "paper" && $0.depth == 0 }
        case .header: return blocks.first { $0.name == "header" && $0.depth == 0 }
        case .layout: return layoutBlock
        case let .context(name):
            guard let layout = layoutBlockIndex else { return nil }
            return blocks.first { $0.name == "context" && $0.context == name && $0.parent == layout }
        }
    }

    private var layoutBlockIndex: Int? {
        if let score = blocks.firstIndex(where: { $0.name == "score" && $0.depth == 0 }),
           let layout = blocks.firstIndex(where: { $0.name == "layout" && $0.parent == score }) {
            return layout
        }
        return blocks.firstIndex { $0.name == "layout" && $0.depth == 0 }
    }

    private var layoutBlock: Block? { layoutBlockIndex.map { blocks[$0] } }

    /// Every block of the root where a location's statements take effect,
    /// in file order: any top-level `\paper`; any `\layout`; for context
    /// settings, any `\Score` or `\Staff` context in a `\layout` (a
    /// Staff property or grob set in Score reaches every staff).
    private func candidates(for location: EngravingSetting.Location) -> [Block] {
        let layouts = Set(blocks.indices.filter { blocks[$0].name == "layout" })
        switch location {
        case .paper: return blocks.filter { $0.name == "paper" && $0.depth == 0 }
        case .header: return blocks.filter { $0.name == "header" && $0.depth == 0 }
        case .layout: return blocks.filter { $0.name == "layout" }
        case .context:
            return blocks.filter { b in
                b.name == "context" && ["Score", "Staff"].contains(b.context ?? "") && b.parent.map(layouts.contains) == true
            }
        }
    }

    /// The setting's statements in the root, in file order.
    private func rootStatements(for setting: EngravingSetting) -> [Statement] {
        candidates(for: setting.location).flatMap { statements(for: setting, in: $0) }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Statements

    struct Statement {
        var range: Range<Int>
        var text: String
    }

    /// Statements written directly in `block` (not in a block inside it)
    /// that belong to `setting`.
    private func statements(for setting: EngravingSetting, in block: Block?) -> [Statement] {
        guard let block else { return [] }
        let keys = setting.keys + setting.readKeys
        return statements(in: block).filter { s in keys.contains { Self.starts(s.text, with: $0) } }
    }

    private func statements(in block: Block) -> [Statement] {
        let inner = blocks.filter { $0.open > block.open && $0.close < block.close }.map { $0.command.lowerBound...$0.close }
        var result: [Statement] = []
        var i = block.body.lowerBound
        while i < block.body.upperBound {
            // A statement starts a line, or follows the block's `{` (or `\Score`).
            while i < block.body.upperBound, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
            if i < block.body.upperBound, !inner.contains(where: { $0.contains(i) }), bytes[i] != 0x0A, bytes[i] != 0x25 {
                let end = statementEnd(from: i, limit: block.body.upperBound)
                if end > i { result.append(Statement(range: i..<end, text: String(decoding: bytes[i..<end], as: UTF8.self))) }
            }
            while i < block.body.upperBound, bytes[i] != 0x0A { i += 1 }
            i += 1
        }
        return result
    }

    /// Where a statement ends: the end of its line, or of its last line
    /// when parentheses or a string carry it on; never a trailing comment.
    private func statementEnd(from start: Int, limit: Int) -> Int {
        var depth = 0
        var inString = false
        var i = start
        var end = start
        while i < limit {
            let b = bytes[i]
            if inString {
                if b == 0x5C { i += 2; end = min(i, limit); continue }
                if b == 0x22 { inString = false }
            } else {
                if b == 0x22 { inString = true }
                if b == 0x28 { depth += 1 }
                if b == 0x29 { depth -= 1 }
                if b == 0x25, depth <= 0 { break }               // % comment
                if b == 0x0A, depth <= 0 { break }
            }
            if b != 0x20, b != 0x09, b != 0x0A { end = i + 1 }
            i += 1
        }
        return end
    }

    private func dictionary(_ statements: [Statement], extraKeys: [String] = []) -> [String: String] {
        var result: [String: String] = [:]
        for s in statements {
            for key in EngravingSetting.all.flatMap({ $0.keys + $0.readKeys }) + extraKeys where Self.starts(s.text, with: key) {
                result[key] = s.text
            }
        }
        return result
    }

    /// `text` begins with `key` as whole words: `autoBeaming` is not
    /// `autoBeamingX`, and `system-system-spacing` is not `…spacing.basic-distance`.
    static func starts(_ text: String, with key: String) -> Bool {
        guard text.hasPrefix(key) else { return false }
        guard let next = text.dropFirst(key.count).first else { return true }
        if key.hasPrefix("#(") { return next == " " || next == ")" }
        return next == " " || next == "=" || next == "\t"
    }

    /// Statements of `setting` in the other files, with their lines.
    private func elsewhereStatements(for setting: EngravingSetting) -> [Where] {
        let keys = setting.keys + setting.readKeys
        var result: [Where] = []
        var candidates = Set<Int>()
        for key in keys {
            guard let first = Self.words(key).first else { continue }
            candidates.formUnion(otherWords[first] ?? [])
        }
        for index in candidates.sorted() {
            let (file, line, text) = otherLines[index]
            // `\context { \Score autoBeaming = ##f }` on one line, too.
            for key in keys {
                if Self.starts(text, with: key) {
                    result.append(Where(file: file, line: line, statement: text))
                } else if let range = text.firstRange(of: key), range.lowerBound > text.startIndex,
                          text[text.index(before: range.lowerBound)] == " ",
                          Self.starts(String(text[range.lowerBound...]), with: key) {
                    result.append(Where(file: file, line: line, statement: String(text[range.lowerBound...])))
                }
            }
        }
        return result
    }

    // MARK: Edit shapes

    /// The statement's whole line, newline included, when nothing else is on it.
    private func lineRange(of range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
        var end = range.upperBound
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        // A comment after it is about it: it goes too.
        if end < bytes.count, bytes[end] == 0x25 { while end < bytes.count, bytes[end] != 0x0A { end += 1 } }
        let ownsLine = (start == 0 || bytes[start - 1] == 0x0A) && (end == bytes.count || bytes[end] == 0x0A)
        if ownsLine { return start..<min(bytes.count, end + 1) }
        return range
    }

    private func indentation(at offset: Int) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// One more line at the end of `block`, indented like its statements.
    private func insertion(of lines: [String], into block: Block) -> TextEdit {
        let outer = indentation(at: block.command.lowerBound)
        let indent = statements(in: block).last.map { indentation(at: $0.range.lowerBound) } ?? outer + "  "
        // After the last thing in the block, before the `}`.
        var at = block.close
        while at > block.body.lowerBound, [0x20, 0x09, 0x0A].contains(bytes[at - 1]) { at -= 1 }
        let closeOnOwnLine = bytes[at..<block.close].contains(0x0A)
        let text = lines.map { "\n" + indent + $0 }.joined() + (closeOnOwnLine ? "" : "\n" + outer)
        return .insert(text, at: at)
    }

    /// A block the root lacks, with `lines` in it.
    private func creation(of lines: [String], at location: EngravingSetting.Location) -> TextEdit {
        switch location {
        case let .context(name):
            let context = ["\\context {", "  \\\(name)"] + lines.map { "  " + $0 } + ["}"]
            if let layout = layoutBlock { return insertion(of: context, into: layout) }
            return topLevel(name: "layout", body: ["\\context {", "  \\\(name)"] + lines.map { "  " + $0 } + ["}"])
        case .layout:
            return topLevel(name: "layout", body: lines)
        case .paper:
            return topLevel(name: "paper", body: lines)
        case .header:
            return topLevel(name: "header", body: lines)
        }
    }

    /// A new top-level block. `\layout` goes in the first `\score` when
    /// there is one (it applies there, not to later scores), `\header` and
    /// `\paper` before the first `\score` or `\book`, else at the end.
    private func topLevel(name: String, body: [String]) -> TextEdit {
        if name == "layout", let score = blocks.first(where: { $0.name == "score" && $0.depth == 0 }) {
            let lines = ["\\layout {"] + body.map { "  " + $0 } + ["}"]
            return insertion(of: lines, into: score)
        }
        let block = "\\\(name) {\n" + body.map { "  " + $0 + "\n" }.joined() + "}\n"
        if let first = blocks.first(where: { ["score", "book", "bookpart"].contains($0.name) && $0.depth == 0 }) {
            var start = first.command.lowerBound
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            return .insert(block + "\n", at: start)
        }
        let needsNewline = !bytes.isEmpty && bytes.last != 0x0A
        return .insert((needsNewline ? "\n\n" : "\n") + block, at: bytes.count)
    }
}

/// The special symbols a score's performers read: what its legend should
/// explain (DESIGN.md §11, "Legend candidates").
///
/// The rule is simple and needs no list of techniques: a symbol is a
/// command the score defines itself (a music or event function, or a
/// variable of overrides with no notes in it, in any of its files) that
/// appears in the music of an instrumental staff. LilyPond's own commands
/// are standard notation and need no legend; electronics staves are the
/// patch's. Literal number, boolean and symbol arguments make variants
/// (`\wind #1`, `\wind #0.75`); a `\slapOn` … `\slapOff` pair is one symbol.
///
/// Each candidate carries a legend example rebuilt from its first use in
/// the score: the real pitches, as absolute notes, around the command.
public struct LegendCandidate: Sendable, Hashable, Identifiable {
    /// The legend row's id: the command, then its variant (`wind-0.75`).
    public var id: String
    public var command: String
    /// The literal arguments that make this variant, as written (`#0.75`).
    public var variant: [String]
    public var title: String
    /// The comment above the command's definition, if any.
    public var text: String
    /// A markup: `\score { … }`.
    public var example: String
    public var uses: Int
    /// Where it is first used: file index and 1-based line.
    public var file: Int
    public var line: Int
    /// The staff it was found in.
    public var staff: String
    /// False when it most likely prints nothing (playback or layout only):
    /// its definition omits or hides what it makes, or it is named `play…`/`midi…`.
    public var printed: Bool

    public var legendItem: FrontMatter.NewLegendItem {
        FrontMatter.NewLegendItem(id: id, title: title, text: text.isEmpty ? "What it asks of the performer." : text,
                                  example: example)
    }

    /// The command as the score writes it: `\wind #0.75`.
    public var invocation: String { (["\\" + command] + variant).joined(separator: " ") }
}

public enum LegendScan {
    /// LilyPond's own extended-technique commands, which a legend usually explains too.
    public static let builtinSymbols: Set<String> = [
        "xNote", "xNotesOn", "harmonic", "harmonicsOn", "flageolet", "halfopen", "snappizzicato", "stopped",
    ]

    /// Every candidate in the instrumental staves of the score (`files[0]` is the root), in order of first use.
    public static func candidates(files: [String]) -> [LegendCandidate] {
        let scans = files.map { SetupScan($0) }
        let definitions = Definitions(scans)
        let setup = StaffSetup(files: files)
        let language = scans.first?.tree.finalLanguage ?? .nederlands
        var found: [String: LegendCandidate] = [:]
        var order: [String] = []
        for staff in setup.staves where !staff.isElectronics {
            guard let start = scans[staff.file].musicStart[staff.offset] else { continue }
            var walker = Walker(scans: scans, definitions: definitions, language: language, staff: staff.label)
            walker.walk(file: staff.file, leaves: walker.extent(file: staff.file, from: start))
            for c in walker.found {
                if var existing = found[c.id] {
                    existing.uses += c.uses
                    found[c.id] = existing
                } else {
                    found[c.id] = c
                    order.append(c.id)
                }
            }
        }
        var result = order.compactMap { found[$0] }
        // A command with many values (`\playTempo 60`, `\playTempo 80` …) is one symbol with a parameter.
        let counts = Dictionary(grouping: result, by: \.command).mapValues(\.count)
        var merged: [String: Int] = [:]
        result = result.compactMap { c in
            guard (counts[c.command] ?? 0) > LegendScan.maximumVariants else { return c }
            if let i = merged[c.command] {
                _ = i
                return nil
            }
            merged[c.command] = 1
            var one = c
            one.id = c.command
            one.variant = []
            one.title = Walker.title(c.command, [])
            one.uses = result.filter { $0.command == c.command }.reduce(0) { $0 + $1.uses }
            return one
        }
        return result
    }

    /// More values than this and a command's arguments are a parameter, not kinds of symbol.
    public static let maximumVariants = 4
}

// MARK: - Definitions

/// What the score defines at top level, in all its files.
struct Definitions {
    enum Kind: Equatable {
        /// `define-event-function`: attaches to the note before it.
        case event(predicates: [String])
        /// `define-music-function`: its last argument may be music.
        case music(predicates: [String])
        /// A variable: music with notes (followed), or a switch or once-off without.
        case variable(hasNotes: Bool, structural: Bool)
        /// A post-event built in Scheme (`#((fixed-span box) …)`). Such symbols often
        /// lean on the score's own machinery, so their example is left for the user to try.
        case schemeEvent
        case other
    }

    struct Definition {
        var file: Int
        var nameLeaf: Int
        var value: Range<Int>   // leaf indices
        var kind: Kind
        /// The body's text, for spanner starts (`\startTextSpan`).
        var body: String
    }

    var byName: [String: Definition] = [:]
    let scans: [SetupScan]

    static let structuralCommands: Set<String> = ["\\key", "\\time", "\\clef", "\\tempo", "\\bar", "\\partial",
                                                  "\\major", "\\minor", "\\numericTimeSignature", "\\defaultTimeSignature"]

    init(_ scans: [SetupScan]) {
        self.scans = scans
        for (f, s) in scans.enumerated() {
            for (name, valueLeaf) in s.assignments where byName[name] == nil {
                let range = Self.valueExtent(s, from: valueLeaf)
                let first = s.leaves[valueLeaf]
                let body = range.isEmpty ? "" : String(decoding: s.tree.bytes[s.leaves[range.lowerBound].range.lowerBound..<s.leaves[range.upperBound - 1].range.upperBound], as: UTF8.self)
                var kind = Kind.other
                if first.kind == .hash || first.kind == .schemeText {
                    let scheme = body.drop { $0 == "#" || $0 == "$" }
                    if scheme.hasPrefix("(define-event-function") {
                        kind = .event(predicates: Self.predicates(String(scheme)))
                    } else if scheme.hasPrefix("(define-music-function") {
                        kind = .music(predicates: Self.predicates(String(scheme)))
                    } else if scheme.hasPrefix("((") || scheme.hasPrefix("(make-") {
                        // `#((fixed-span box) …)`: a post-event built in Scheme.
                        kind = .schemeEvent
                    }
                } else if first.kind == .direction || first.kind == .articulation || first.kind == .escapedPunct {
                    // `startFloor = -\tweak … \startTextSpan`, `stopBox = \stopTextSpan`-like post-events.
                    kind = .event(predicates: [])
                } else if first.kind == .openBrace || first.kind == .openSimultaneous || first.kind == .command {
                    if first.text == "\\markup" || first.text == "\\markuplist" {
                        kind = .other
                    } else {
                        let start = s.leaves[range.lowerBound].range.lowerBound, end = s.leaves[range.upperBound - 1].range.upperBound
                        // Any event, skips included: a voice of skips carrying spanners is music to look into.
                        let hasNotes = s.tree.events.contains { $0.range.lowerBound >= start && $0.range.lowerBound < end }
                        let commands = range.map { s.leaves[$0] }.filter { $0.kind == .command }.map(\.text)
                        let structural = !commands.isEmpty && commands.allSatisfy { Self.structuralCommands.contains($0) }
                        kind = .variable(hasNotes: hasNotes, structural: structural)
                    }
                }
                byName[name] = Definition(file: f, nameLeaf: valueLeaf - 2, value: range, kind: kind,
                                          body: Self.fullBody(s, from: valueLeaf, fallback: body))
            }
        }
    }

    /// The definition's whole text, to the next top-level assignment: a
    /// Scheme function's `#{ … #}` is lexed as music of its own.
    static func fullBody(_ s: SetupScan, from valueLeaf: Int, fallback: String) -> String {
        let start = s.leaves[valueLeaf].range.lowerBound
        let next = s.assignments.values.filter { $0 > valueLeaf }.min().map { s.leaves[max($0 - 2, 0)].range.lowerBound } ?? s.tree.bytes.count
        guard next > start else { return fallback }
        return String(decoding: s.tree.bytes[start..<min(next, start + 4000)], as: UTF8.self)
    }

    /// The value's leaves: a `{ }`/`<< >>` group, a Scheme datum, or the rest of its line.
    static func valueExtent(_ s: SetupScan, from start: Int) -> Range<Int> {
        guard start < s.leaves.count else { return start..<start }
        let first = s.leaves[start]
        if first.kind == .openBrace || first.kind == .openSimultaneous {
            var depth = 0
            for k in start..<s.leaves.count {
                switch s.leaves[k].kind {
                case .openBrace, .openSimultaneous: depth += 1
                case .closeBrace, .closeSimultaneous:
                    depth -= 1
                    if depth == 0 { return start..<(k + 1) }
                default: break
                }
            }
            return start..<s.leaves.count
        }
        if first.kind == .hash { return start..<min(start + 2, s.leaves.count) }
        // `\override Beam.grow-direction = #RIGHT`, or `\relative c' { … }`: to the end of the line, or of a group opened on it.
        let line = lineEnd(s, after: first.range.lowerBound)
        var k = start
        var depth = 0
        while k < s.leaves.count {
            let l = s.leaves[k]
            if depth == 0, l.range.lowerBound >= line, k > start { break }
            if l.kind == .openBrace || l.kind == .openSimultaneous { depth += 1 }
            if l.kind == .closeBrace || l.kind == .closeSimultaneous { depth -= 1; if depth == 0 { k += 1; break } }
            k += 1
        }
        return start..<k
    }

    static func lineEnd(_ s: SetupScan, after offset: Int) -> Int {
        var i = offset
        while i < s.tree.bytes.count, s.tree.bytes[i] != 0x0A { i += 1 }
        return i
    }

    /// `(define-event-function (text duration) (markup? markup?) …)` → ["markup?", "markup?"].
    static func predicates(_ scheme: String) -> [String] {
        var lists: [String] = []
        var depth = 0
        var current = ""
        for c in scheme {
            if c == "(" {
                depth += 1
                if depth == 2 { current = ""; continue }
            }
            if c == ")" {
                if depth == 2 { lists.append(current); if lists.count == 2 { break } }
                depth -= 1
                if depth < 1 { break }
            }
            if depth >= 2 { current.append(c) }
        }
        guard lists.count == 2 else { return [] }
        // Words, or `(number? 1)` (an optional argument with a default): its first word.
        var preds: [String] = []
        var nesting = 0
        var word = ""
        var tookGroupWord = false
        func flush() {
            if !word.isEmpty, nesting == 0 || !tookGroupWord {
                preds.append(word)
                if nesting > 0 { tookGroupWord = true }
            }
            word = ""
        }
        for c in lists[1] + " " {
            switch c {
            case "(":
                flush()
                nesting += 1
                tookGroupWord = false
            case ")":
                flush()
                nesting -= 1
            case " ", "\n", "\t":
                flush()
            default:
                word.append(c)
            }
        }
        return preds
    }
}

// MARK: - Walking the music

struct Walker {
    let scans: [SetupScan]
    let definitions: Definitions
    let language: PitchLanguage
    let staff: String
    var found: [LegendCandidate] = []
    var visited: Set<String> = []
    /// The bytes of the music being walked: examples take their notes from it.
    var region: Range<Int> = 0..<0

    init(scans: [SetupScan], definitions: Definitions, language: PitchLanguage, staff: String) {
        self.scans = scans
        self.definitions = definitions
        self.language = language
        self.staff = staff
    }

    /// The staff's music: a group, or a variable, or a function and its arguments up to a group.
    func extent(file f: Int, from start: Int) -> Range<Int> {
        let s = scans[f]
        var depth = 0
        var k = start
        while k < s.leaves.count {
            let l = s.leaves[k]
            switch l.kind {
            case .openBrace, .openSimultaneous: depth += 1
            case .closeBrace, .closeSimultaneous:
                depth -= 1
                if depth <= 0 { return start..<(k + 1) }
            case .command where depth == 0:
                if let d = definitions.byName[String(l.text.dropFirst())], case .variable = d.kind { return start..<(k + 1) }
            default: break
            }
            k += 1
        }
        return start..<k
    }

    static let variantPredicates: Set<String> = ["number?", "boolean?", "symbol?", "real?",
                                                 "exact-rational?", "positive?", "rational?", "number-pair?", "boolean-or-symbol?"]

    mutating func walk(file f: Int, leaves range: Range<Int>) {
        let s = scans[f]
        guard !range.isEmpty else { return }
        let saved = region
        region = s.leaves[range.lowerBound].range.lowerBound..<s.leaves[range.upperBound - 1].range.upperBound
        defer { region = saved }
        var k = range.lowerBound
        while k < range.upperBound {
            let leaf = s.leaves[k]
            guard leaf.kind == .command else { k += 1; continue }
            let name = String(leaf.text.dropFirst())
            if let d = definitions.byName[name] {
                switch d.kind {
                case .variable(hasNotes: true, _):
                    // Music: look inside it, once.
                    if !visited.contains(name) {
                        visited.insert(name)
                        walk(file: d.file, leaves: d.value)
                    }
                case .variable(hasNotes: false, structural: false):
                    if partner(ending: name) != nil { break }
                    record(file: f, at: k, name: name, definition: d, arguments: [], argumentText: "", after: k + 1)
                case .schemeEvent:
                    if partner(ending: name) == nil {
                        record(file: f, at: k, name: name, definition: d, arguments: [], argumentText: "", after: k + 1)
                    }
                case let .event(predicates), let .music(predicates):
                    if partner(ending: name) != nil { k += 1; continue }
                    let (args, text, next) = arguments(s, after: k, predicates: predicates)
                    record(file: f, at: k, name: name, definition: d, arguments: args, argumentText: text, after: next)
                default:
                    break
                }
            } else if LegendScan.builtinSymbols.contains(name) {
                record(file: f, at: k, name: name, definition: nil, arguments: [], argumentText: "", after: k + 1)
            }
            k += 1
        }
    }

    /// `slapOff` ends `slapOn`, `stopBox` ends `startBox`: the start's name.
    func partner(ending name: String) -> String? {
        if name.hasSuffix("Off"), definitions.byName[String(name.dropLast(3)) + "On"] != nil { return String(name.dropLast(3)) + "On" }
        if name.hasPrefix("stop"), definitions.byName["start" + name.dropFirst(4)] != nil { return "start" + name.dropFirst(4) }
        return nil
    }

    /// `slapOn` → `slapOff`, `startBox` → `stopBox`, if the score defines it.
    func ending(of name: String) -> String? {
        if name.hasSuffix("On"), definitions.byName[String(name.dropLast(2)) + "Off"] != nil { return String(name.dropLast(2)) + "Off" }
        if name.hasPrefix("start"), definitions.byName["stop" + name.dropFirst(5)] != nil { return "stop" + name.dropFirst(5) }
        return nil
    }

    /// The literal arguments after a function: those that make a variant, all
    /// of them as written, and the leaf after the last non-music one.
    func arguments(_ s: SetupScan, after k: Int, predicates: [String]) -> ([String], String, Int) {
        var variant: [String] = []
        var j = k + 1
        var start: Int?
        var end: Int?
        for pred in predicates {
            if pred == "ly:music?" || j >= s.leaves.count { break }
            let l = s.leaves[j]
            var last = j
            if l.kind == .hash, j + 1 < s.leaves.count {
                last = j + 1
            } else if l.kind == .command, l.text == "\\markup" {
                // `\markup` and its argument: a group, or commands up to a string.
                var m = j + 1
                if m < s.leaves.count, s.leaves[m].kind == .openBrace, let close = s.matching(from: m) {
                    m = close
                } else {
                    while m < s.leaves.count, s.leaves[m].kind == .command { m += 1 }
                }
                last = min(m, s.leaves.count - 1)
            } else if l.kind == .command || l.kind == .openBrace || l.kind == .closeBrace {
                break
            }
            let text = String(decoding: s.tree.bytes[l.range.lowerBound..<s.leaves[last].range.upperBound], as: UTF8.self)
            if Self.variantPredicates.contains(pred) { variant.append(text) }
            if start == nil { start = l.range.lowerBound }
            end = s.leaves[last].range.upperBound
            j = last + 1
        }
        let text = start.map { String(decoding: s.tree.bytes[$0..<end!], as: UTF8.self) } ?? ""
        return (variant, text, j)
    }

    mutating func record(file f: Int, at k: Int, name: String, definition d: Definitions.Definition?, arguments: [String],
                         argumentText: String, after next: Int) {
        let id = ([name] + arguments.map(Self.slug)).joined(separator: "-")
        if let i = found.firstIndex(where: { $0.id == id }) {
            found[i].uses += 1
            return
        }
        let s = scans[f]
        let offset = s.leaves[k].range.lowerBound
        let call = (["\\" + name] + (argumentText.isEmpty ? [] : [argumentText])).joined(separator: " ")
        let example = self.example(f, offset: offset, nextLeaf: next, name: name, call: call, definition: d)
        found.append(LegendCandidate(id: id, command: name, variant: arguments, title: Self.title(name, arguments),
                                     text: d.map { comment(above: $0) } ?? "", example: example, uses: 1, file: f,
                                     line: s.line(of: offset), staff: staff, printed: Self.printed(name, d)))
    }

    static func printed(_ name: String, _ d: Definitions.Definition?) -> Bool {
        if name.hasPrefix("play") || name.hasPrefix("midi") { return false }
        guard let body = d?.body else { return true }
        return !["\\omit", "stencil ##f", "stencil = ##f", "\\hide", "transparent = ##t", "\\tag #'played"].contains { body.contains($0) }
            || body.contains("\\tag #'printed")
    }

    // MARK: Examples

    func example(_ f: Int, offset: Int, nextLeaf: Int, name: String, call: String, definition d: Definitions.Definition?) -> String {
        let s = scans[f]
        let after = nextLeaf < s.leaves.count ? s.leaves[nextLeaf].range.lowerBound : s.tree.bytes.count
        let before = notes(s, before: offset, count: 1).first ?? "c''4"
        let following = notes(s, from: after, count: 3)
        func next(_ n: Int) -> [String] { following.count >= n ? Array(following.prefix(n)) : following + Array(repeating: "c''4", count: n - following.count) }
        var music: String
        let beams = d?.body.contains("Beam") == true
        func group(_ n: [String]) -> String {
            guard beams, n.count > 1 else { return n.joined(separator: " ") }
            return n[0] + "[ " + n.dropFirst().joined(separator: " ") + "]"
        }
        let first = definitions.byName[name].flatMap { def in def.value.isEmpty ? nil : scans[def.file].leaves[def.value.lowerBound].text }
        switch d?.kind {
        case .event?, .schemeEvent?:
            music = "\(before) \(call)"
            if let end = ending(of: name) {
                let n = next(2)
                music += " \(n[0]) \(n[1])\\\(end)"
            } else if let stop = Self.spannerStop(in: d!.body) {
                let n = next(2)
                music += " \(n[0]) \(n[1])\(stop)"
            }
        case let .music(predicates)? where predicates.last == "ly:music?":
            music = "\(call) { \(group(next(3))) }"
        default:
            if let end = ending(of: name) {
                music = "\(call) \(group(next(3))) \\\(end)"
            } else if ["\\once", "\\override", "\\revert", "\\set", "\\unset"].contains(first ?? "") || !Self.followsAnEvent(s, offset: offset) {
                music = "\(call) \(group(next(3)))"
            } else {
                music = "\(before) \(call)"
            }
        }
        let score = "\\score { \\new Staff \\with { \\remove Time_signature_engraver } { \\cadenzaOn \(music) } "
            + "\\layout { indent = 0 ragged-right = ##t line-width = 40\\mm } }"
        if case .schemeEvent? = d?.kind { return "\\null % notation, if it draws outside the score: " + score }
        return score
    }

    /// The `\stopX` that ends a spanner the function starts (`\startTextSpan` → `\stopTextSpan`).
    static func spannerStop(in body: String) -> String? {
        guard let r = body.firstRange(of: "\\start") else { return nil }
        let name = body[r.upperBound...].prefix { $0.isLetter }
        return name.isEmpty ? nil : "\\stop" + name
    }

    /// Whether the command comes straight after a note, rest or skip (`s4 \caes`).
    static func followsAnEvent(_ s: SetupScan, offset: Int) -> Bool {
        guard let prev = s.leaves.lastIndex(where: { $0.range.upperBound <= offset }) else { return false }
        let end = s.leaves[prev].range.upperBound
        return s.tree.events.contains { $0.range.upperBound == end }
    }

    /// Pitched events as absolute notes with their durations.
    func notes(_ s: SetupScan, before offset: Int, count: Int) -> [String] {
        Array(s.tree.events.filter { $0.range.upperBound <= offset && region.contains($0.range.lowerBound) && $0.isPitched }
            .suffix(count).map { spell($0, s) })
    }

    func notes(_ s: SetupScan, from offset: Int, count: Int) -> [String] {
        Array(s.tree.events.filter { $0.range.lowerBound >= offset && region.contains($0.range.lowerBound) && $0.isPitched }
            .prefix(count).map { spell($0, s) })
    }

    func spell(_ e: MusicEvent, _ s: SetupScan) -> String {
        let pitches = e.notes.map { i -> String in
            let p = s.tree.notes[i].absolute
            let marks = p.octave > 0 ? String(repeating: "'", count: p.octave) : String(repeating: ",", count: -p.octave)
            return language.spell(step: p.step, alteration: p.alteration) + marks
        }
        let duration = e.effectiveDuration.text
        return pitches.count == 1 ? pitches[0] + duration : "<" + pitches.joined(separator: " ") + ">" + duration
    }

    // MARK: Words

    /// `slapOn` → "Slap", `timeField` → "Time field", `wind #0.75` → "Wind 0.75".
    static func title(_ name: String, _ arguments: [String]) -> String {
        var base = name
        if base.hasSuffix("On"), base.count > 2 { base = String(base.dropLast(2)) }
        var words = ""
        for c in base {
            if c.isUppercase, !words.isEmpty { words += " " + c.lowercased() } else { words.append(c) }
        }
        let head = words.prefix(1).uppercased() + words.dropFirst()
        let args = arguments.map { $0.drop { $0 == "#" || $0 == "'" } }.joined(separator: " ")
        return args.isEmpty ? head : "\(head) \(args)"
    }

    static func slug(_ argument: String) -> String {
        String(argument.drop { $0 == "#" || $0 == "'" }.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
    }

    /// The comment lines directly above the definition, without `%`; rules
    /// (`%% ---- slap tongue`) are skipped.
    func comment(above d: Definitions.Definition) -> String {
        let s = scans[d.file]
        guard d.nameLeaf >= 0 else { return "" }
        let bytes = s.tree.bytes
        var lineStart = s.leaves[d.nameLeaf].range.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var lines: [String] = []
        var end = lineStart - 1
        while end > 0 {
            var start = end
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            let line = String(decoding: bytes[start..<end], as: UTF8.self).trimmedSpaces
            guard line.hasPrefix("%") else { break }
            let text = line.drop { $0 == "%" }.trimmedSpaces
            if !text.hasPrefix("---"), !text.hasPrefix("==="), !text.isEmpty { lines.insert(text, at: 0) }
            end = start - 1
        }
        return lines.joined(separator: " ")
    }
}

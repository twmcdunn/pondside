public struct LensClef: Sendable, Hashable {
    public var sign: String
    public var line: Int
    public var name: String

    public init(sign: String, line: Int, name: String) {
        self.sign = sign
        self.line = line
        self.name = name
    }

    public static let treble = LensClef(sign: "G", line: 2, name: "treble")

    public static func named(_ name: String) -> LensClef? {
        // `treble_8` and `"bass^15"` keep their base clef; the octave mark is dropped.
        let base = name.lowercased().split(whereSeparator: { $0 == "_" || $0 == "^" }).first.map(String.init) ?? ""
        switch base {
        case "treble", "g", "g2", "violin": return .treble
        case "french", "g1": return LensClef(sign: "G", line: 1, name: "french")
        case "bass", "f", "f4": return LensClef(sign: "F", line: 4, name: "bass")
        case "baritone", "f3": return LensClef(sign: "F", line: 3, name: "baritone")
        case "subbass", "f5": return LensClef(sign: "F", line: 5, name: "subbass")
        case "alto", "c3", "viola", "c": return LensClef(sign: "C", line: 3, name: "alto")
        case "tenor", "c4": return LensClef(sign: "C", line: 4, name: "tenor")
        case "mezzosoprano", "mezzo-soprano", "c2": return LensClef(sign: "C", line: 2, name: "mezzo-soprano")
        case "soprano", "c1": return LensClef(sign: "C", line: 1, name: "soprano")
        case "percussion": return LensClef(sign: "percussion", line: 0, name: "percussion")
        default: return nil
        }
    }
}

public struct LensTime: Sendable, Hashable {
    public var beats: Int
    public var beatType: Int

    public init(beats: Int, beatType: Int) {
        self.beats = beats
        self.beatType = beatType
    }

    public static let common = LensTime(beats: 4, beatType: 4)

    var wholeNotes: LensFraction {
        LensFraction(beats, beatType)
    }
}

/// `\tuplet 3/2 { … }`: three notes in the time of two.
struct LensTuplet: Sendable, Hashable {
    var actualNotes: Int
    var normalNotes: Int
    var body: Range<Int>
}

/// `\repeat tremolo 16 { a32 b32 }`: the body played `count` times.
struct LensTremolo: Sendable, Hashable {
    var count: Int
    var body: Range<Int>
}

/// What the block says besides its notes, keyed by source offset.
struct LensContext: Sendable {
    var clefs: [(offset: Int, clef: LensClef)] = []
    var times: [(offset: Int, time: LensTime)] = []
    var partials: [(offset: Int, length: LensFraction)] = []
    var tuplets: [LensTuplet] = []
    var tremolos: [LensTremolo] = []
    var graces: [Range<Int>] = []
    /// `\collection { … }` bodies: no time, like graces (and in `graces`).
    var collections: [Range<Int>] = []
    var unsupported: [String] = []
    var custom: [String] = []
    var managedMeasures: [(body: Range<Int>, time: LensTime)] = []

    func clef(at offset: Int) -> LensClef {
        clefs.last { $0.offset <= offset }?.clef ?? .treble
    }

    /// Tuplets around `offset`, outermost first.
    func tuplets(at offset: Int) -> [LensTuplet] {
        tuplets.filter { $0.body.contains(offset) }
    }

    func tremolo(at offset: Int) -> LensTremolo? {
        tremolos.last { $0.body.contains(offset) }
    }

    func durationFactor(at offset: Int) -> LensFraction {
        let tuplet = tuplets(at: offset).reduce(LensFraction.one) { $0 * LensFraction($1.normalNotes, $1.actualNotes) }
        return tremolos.filter { $0.body.contains(offset) }.reduce(tuplet) { $0 * LensFraction($1.count) }
    }

    func isGrace(at offset: Int) -> Bool {
        graces.contains { $0.contains(offset) }
    }

    func isCollection(at offset: Int) -> Bool {
        collections.contains { $0.contains(offset) }
    }

    mutating func flag(_ text: String) {
        if !unsupported.contains(text) { unsupported.append(text) }
    }

    /// The badges to show, custom commands summarised last.
    var badges: [String] {
        guard !custom.isEmpty else { return unsupported }
        let names = custom.prefix(3).map { "\\" + $0 }.joined(separator: " ")
        let more = custom.count > 3 ? " +\(custom.count - 3)" : ""
        return unsupported + ["graphic: \(names)\(more)"]
    }
}

enum LensContextScanner {
    struct Leaf {
        var kind: SyntaxKind
        var range: Range<Int>
        var text: String
    }

    /// Commands the lens does not reproduce faithfully.
    private static let unsupportedCommands: Set<String> = [
        "repeat", "alternative", "transpose", "ottava", "tag", "keepWithTag", "removeWithTag",
        "modalTranspose", "modalInversion", "inversion", "retrograde", "musicMap", "lexicon",
        "compoundMeter", "scaleDurations", "afterGrace", "change", "unfoldRepeats",
    ]

    /// LilyPond commands that change nothing the lens draws, or that it
    /// reads itself. Anything else is assumed to be a custom definition.
    private static let builtins: Set<String> = [
        "clef", "time", "key", "partial", "undo", "tuplet", "times", "grace", "acciaccatura", "appoggiatura",
        "slashedGrace", "bar", "barNumberCheck", "once", "tempo", "mark", "textMark", "fine",
        "break", "noBreak", "pageBreak", "noPageBreak", "pageTurn", "allowPageTurn",
        "autoLineBreaksOff", "autoLineBreaksOn", "autoPageBreaksOff", "autoPageBreaksOn", "newSpacingSection",
        "autoBeamOn", "autoBeamOff", "cadenzaOn", "cadenzaOff", "default", "global",
        "stemUp", "stemDown", "stemNeutral", "slurUp", "slurDown", "slurNeutral", "slurDashed",
        "slurDotted", "slurSolid", "tieUp", "tieDown", "tieNeutral", "dynamicUp", "dynamicDown",
        "dynamicNeutral", "tupletUp", "tupletDown", "tupletNeutral", "voiceOne", "voiceTwo",
        "voiceThree", "voiceFour", "oneVoice", "phrasingSlurUp", "phrasingSlurDown",
        "textLengthOn", "textLengthOff", "hideNotes", "unHideNotes", "deadNote", "xNote",
        "harmonicsOn", "harmonicsOff", "improvisationOn", "improvisationOff", "hairpinStraight",
        "major", "minor", "ionian", "dorian", "phrygian", "lydian", "mixolydian", "aeolian", "locrian",
        "relative", "fixed", "absolute", "language", "version", "include", "numericTimeSignature",
        "defaultTimeSignature", "shiftOn", "shiftOff", "shiftOnn", "shiftOnnn", "mergeDifferentlyDottedOn",
        "mergeDifferentlyHeadedOn", "accidentalStyle", "breathe", "caesura", "featherDurations",
        "tweak", "parenthesize", "footnote", "bendAfter", "glissando", "markup", "markuplist",
        "sustainOn", "sustainOff", "inStaffSegno", "section", "sectionLabel", "codaMark", "segnoMark",
        "startStaff", "stopStaff", "magnifyMusic", "teeny", "tiny", "small", "normalsize", "large",
        "huge", "easyHeadsOn", "easyHeadsOff", "balloonGrobText", "breve", "longa",
        "maxima", "staffHighlight", "stopStaffHighlight", "skip", "label", "beamExceptions",
    ]

    /// Whole-file facts every scan needs, gathered once.
    struct Source {
        var tree: SyntaxTree
        var leaves: [Leaf] = []
        var variables: [String: Range<Int>]
        var bodies: [Int: Range<Int>]

        init(_ tree: SyntaxTree) {
            self.tree = tree
            var leaves: [Leaf] = []
            tree.root.forEachLeaf { node in
                guard !node.kind.isTrivia else { return }
                leaves.append(Leaf(kind: node.kind, range: node.range, text: tree.string(node.range)))
            }
            self.leaves = leaves
            variables = LensContextScanner.topLevelVariables(in: tree)
            bodies = LensContextScanner.musicNodesByStart(in: tree)
        }

        /// Leaves inside `range`, found by binary search.
        func leaves(in range: Range<Int>) -> ArraySlice<Leaf> {
            var low = 0, high = leaves.count
            while low < high {
                let mid = (low + high) / 2
                if leaves[mid].range.lowerBound < range.lowerBound { low = mid + 1 } else { high = mid }
            }
            var end = low
            while end < leaves.count, leaves[end].range.upperBound <= range.upperBound { end += 1 }
            return leaves[low..<end]
        }
    }

    static func scan(_ tree: SyntaxTree, block: Range<Int>) -> LensContext {
        var context = LensContext()
        scan(Source(tree), range: block, at: nil, into: &context, depth: 0)
        return context
    }

    static func scan(_ source: Source, block: Range<Int>) -> LensContext {
        var context = LensContext()
        scan(source, range: block, at: nil, into: &context, depth: 0)
        return context
    }

    /// Scans `range`. With `at`, everything found counts as written at that
    /// offset: the reference to a variable such as `\global`.
    private static func scan(_ source: Source, range: Range<Int>, at reference: Int?, into context: inout LensContext,
                             depth: Int) {
        let leaves = Array(source.leaves(in: range))
        var index = 0
        while index < leaves.count {
            defer { index += 1 }
            let leaf = leaves[index]
            guard leaf.kind == .command else { continue }
            let offset = reference ?? leaf.range.lowerBound
            let name = String(leaf.text.dropFirst())
            switch name {
            case "clef":
                if let value = leaves[safe: index + 1], let clef = LensClef.named(value.text.trimmingQuotes) {
                    context.clefs.append((offset, clef))
                }
            case "time":
                if let numbers = numbers(in: leaves, after: index, count: 2) {
                    context.times.append((offset, LensTime(beats: numbers[0], beatType: numbers[1])))
                } else {
                    context.flag("time")
                }
            case "partial":
                if let length = duration(in: leaves, after: index) {
                    context.partials.append((offset, length))
                } else {
                    context.flag("partial")
                }
            case "tuplet", "times":
                // `\tuplet 3/2` is actual/normal; the older `\times 2/3` is the inverse.
                if reference == nil, let numbers = numbers(in: leaves, after: index, count: 2),
                   numbers[0] > 0, numbers[1] > 0,
                   let body = body(after: leaf.range.upperBound, leaves: leaves, from: index, nodes: source.bodies) {
                    let (actual, normal) = name == "tuplet" ? (numbers[0], numbers[1]) : (numbers[1], numbers[0])
                    context.tuplets.append(LensTuplet(actualNotes: actual, normalNotes: normal, body: body))
                }
            case "repeat":
                // `\repeat tremolo 16 { … }` is timing the lens can draw; other repeats are not.
                if let kind = leaves[safe: index + 1], kind.text == "tremolo" {
                    if reference == nil, let count = numbers(in: leaves, after: index + 1, count: 1)?.first, count > 0,
                       let body = body(after: kind.range.upperBound, leaves: leaves, from: index + 1, nodes: source.bodies) {
                        context.tremolos.append(LensTremolo(count: count, body: body))
                    }
                } else {
                    context.flag(name)
                }
            case "grace", "acciaccatura", "appoggiatura", "slashedGrace":
                if reference == nil,
                   let body = body(after: leaf.range.upperBound, leaves: leaves, from: index, nodes: source.bodies) {
                    context.graces.append(body)
                }
            case "collection":
                // A pitch collection takes no time (pondside-collections.ily).
                if reference == nil,
                   let body = body(after: leaf.range.upperBound, leaves: leaves, from: index, nodes: source.bodies) {
                    context.graces.append(body)
                    context.collections.append(body)
                }
            case "markup", "markuplist":
                // Markup is text, and its commands are not music.
                context.flag("markup")
                index = skipArgument(in: leaves, after: index)
            case "pondsideMeasure", "pondsideSpace", "pondsideLayout", "pondsideTimeline":
                break
            default:
                if name.hasPrefix("pondsideBar") { continue }
                if unsupportedCommands.contains(name) {
                    context.flag(name)
                } else if let value = source.variables[name] {
                    // `\global`: its clefs and meters count where it is used.
                    // Music in a variable is not drawn, so say so.
                    let tree = source.tree
                    if tree.events.contains(where: { value.contains($0.range.lowerBound) && $0.kind != .lyric }) {
                        context.flag("music variable")
                    } else if depth < 4 {
                        scan(source, range: value, at: offset, into: &context, depth: depth + 1)
                    }
                } else if !builtins.contains(name), !isKnown(name), !context.custom.contains(name) {
                    context.custom.append(name)
                }
            }
        }
    }

    private static func isKnown(_ name: String) -> Bool {
        KnownCommands.postEvents.contains(name) || KnownCommands.postEventsWithArgument.contains(name)
            || KnownCommands.pitchArguments[name] != nil || KnownCommands.propertyPath.contains(name)
            || KnownCommands.contextSpec.contains(name) || KnownCommands.identifierArgument.contains(name)
            || KnownCommands.modes[name] != nil || KnownCommands.durationNames.contains(name)
    }

    /// Top-level `name = { … }` values, by name.
    fileprivate static func topLevelVariables(in tree: SyntaxTree) -> [String: Range<Int>] {
        var result: [String: Range<Int>] = [:]
        let children = tree.root.children
        for (i, node) in children.enumerated() where node.kind == .assignment {
            guard let name = node.children.first else { continue }
            guard let value = children[(i + 1)...].first(where: { !$0.kind.isTrivia }),
                  value.kind == .sequential || value.kind == .simultaneous else { continue }
            result[tree.string(name.range)] = value.range
        }
        return result
    }

    /// Braced expressions and events by their first byte, so a command's
    /// argument can be found from the token that starts it.
    fileprivate static func musicNodesByStart(in tree: SyntaxTree) -> [Int: Range<Int>] {
        var result: [Int: Range<Int>] = [:]
        tree.root.forEachNode { node in
            guard [.sequential, .simultaneous, .event].contains(node.kind) else { return }
            if let existing = result[node.range.lowerBound], existing.count >= node.range.count { return }
            result[node.range.lowerBound] = node.range
        }
        return result
    }

    /// The music argument after `\tuplet 3/2` or `\grace`: the first braced
    /// expression or event at or after `offset`.
    private static func body(after offset: Int, leaves: [Leaf], from index: Int, nodes: [Int: Range<Int>]) -> Range<Int>? {
        for leaf in leaves[(index + 1)...] where leaf.range.lowerBound >= offset {
            if let node = nodes[leaf.range.lowerBound] { return node }
            if leaf.kind == .command { return nil }
        }
        return nil
    }

    /// Index of the last leaf of the argument after `index`.
    private static func skipArgument(in leaves: [Leaf], after index: Int) -> Int {
        guard let next = leaves[safe: index + 1] else { return index }
        guard next.kind == .openBrace else { return index + 1 }
        var depth = 0
        var i = index + 1
        while i < leaves.count {
            if leaves[i].kind == .openBrace { depth += 1 }
            if leaves[i].kind == .closeBrace {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return leaves.count - 1
    }

    private static func numbers(in leaves: [Leaf], after index: Int, count: Int) -> [Int]? {
        var values: [Int] = []
        var i = index + 1
        while i < leaves.count, values.count < count {
            let leaf = leaves[i]
            if leaf.kind == .number, let value = Int(leaf.text) {
                values.append(value)
            } else if leaf.text != "/" {
                break
            }
            i += 1
        }
        return values.count == count ? values : nil
    }

    /// `\partial 4.` or `\partial 8*3`, as a fraction of a whole note.
    private static func duration(in leaves: [Leaf], after index: Int) -> LensFraction? {
        var text = ""
        var i = index + 1
        while i < leaves.count, [.number, .dot, .punctuation, .duration].contains(leaves[i].kind) || leaves[i].text == "*" {
            text += leaves[i].text
            i += 1
        }
        guard let value = DurationValue(text: text) else { return nil }
        let whole = value.wholeNotes
        return LensFraction(whole.0, whole.1)
    }
}

private extension String {
    var trimmingQuotes: String {
        guard count >= 2, first == "\"", last == "\"" else { return self }
        return String(dropFirst().dropLast())
    }
}

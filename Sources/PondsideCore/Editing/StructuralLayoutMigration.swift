extension StructuralEditing {
    /// Expand only deterministic spacer repeats. Duplicating relative-pitch
    /// music would give GUI selection an ambiguous meaning and is not needed
    /// to import a layout track.
    static func expandLayoutRepeats(_ files: [File]) throws -> [File] {
        try files.map { source in
            var file = source
            for _ in 0..<16 {
                let tree = file.tree
                var candidates: [(Range<Int>, String)] = []
                tree.root.forEachNode { node in
                    let children = node.children.filter { !$0.kind.isTrivia }
                    for i in children.indices where children[i].kind == .command && tree.string(children[i].range) == "\\repeat" {
                        guard !isTemplate(in: tree, at: children[i].range.lowerBound),
                              i + 3 < children.count, tree.string(children[i + 1].range) == "unfold",
                              let count = Int(tree.string(children[i + 2].range)), count > 0, count <= 1024,
                              children[i + 3].kind == .sequential else { continue }
                        let body = children[i + 3].range
                        let events = tree.events.filter { body.contains($0.range.lowerBound) }
                        guard !events.isEmpty, events.allSatisfy({ $0.kind == .spacer }) else { continue }
                        var unsafe = false
                        children[i + 3].forEachLeaf {
                            if $0.kind == .command, !["\\repeat", "\\break", "\\pageBreak", "\\newSpacingSection", "\\override", "\\revert", "\\once", "\\autoLineBreaksOff", "\\autoPageBreaksOff"].contains(tree.string($0.range)) { unsafe = true }
                        }
                        guard !unsafe else { continue }
                        let interior = (body.lowerBound + 1)..<(body.upperBound - 1)
                        let edits = events.filter { $0.explicitDuration == nil }.map {
                            TextEdit.insert($0.effectiveDuration.text, at: $0.durationInsertion - interior.lowerBound)
                        }
                        let text = edits.apply(to: tree.string(interior))
                        guard text.utf8.count * count <= 4_000_000 else { continue }
                        candidates.append((children[i].range.lowerBound..<body.upperBound, String(repeating: "\n" + text + "\n", count: count)))
                    }
                }
                // Normalize innermost repeats first; edits never overlap.
                let inner = candidates.filter { candidate in
                    !candidates.contains { other in candidate.0 != other.0 && candidate.0.contains(other.0.lowerBound) }
                }
                if inner.isEmpty { return file }
                let text = inner.map { TextEdit($0.0, $0.1) }.apply(to: tree.text)
                guard text.utf8.count <= 4_000_000 else { throw Failure("\(file.id): the expanded layout repeat would be too large.") }
                file.tree = file.parse(text)
            }
            throw Failure("\(file.id): layout repeats are nested too deeply to expand safely.")
        }
    }

    struct Space {
        var name: String
        var fraction: LensFraction
        var range: Range<Int>
    }

    static func spaces(in tree: SyntaxTree, body: Range<Int>) -> [Space] {
        var result: [Space] = []
        tree.root.forEachNode { node in
            let children = node.children.filter { !$0.kind.isTrivia }
            for i in children.indices where children[i].kind == .command && tree.string(children[i].range) == "\\pondsideSpace" && body.contains(children[i].range.lowerBound) {
                guard i + 3 < children.count, children[i + 1].kind == .command,
                      let numerator = Int(tree.string(children[i + 2].range).dropFirst()),
                      let denominator = Int(tree.string(children[i + 3].range).dropFirst()),
                      numerator >= 0, denominator > 0, numerator <= 1_000_000, denominator <= 1_000_000 else { continue }
                result.append(Space(name: String(tree.string(children[i + 1].range).dropFirst()), fraction: LensFraction(numerator, denominator),
                                    range: children[i].range.lowerBound..<children[i + 3].range.upperBound))
            }
        }
        return result
    }

    /// A skip stream is a timeline, not a sequence of bar checks. Split its
    /// skips at canonical boundaries while retaining zero-duration commands at
    /// their original moments. Sections and automatic layout policy stay local;
    /// forced breaks move to the shared definition for that boundary.
    static func migrateLayout(file: File, block: LensBlock, bars: [Bar], sharedBreaks: Bool) throws -> Part {
        let tree = file.tree
        let context = LensContextScanner.scan(tree, block: block.context)
        let unsupported = context.unsupported.filter { $0 != "markup" } + context.custom
        guard unsupported.isEmpty, context.tuplets.isEmpty, context.tremolos.isEmpty else {
            throw Failure("\(file.id): layout track \(block.label ?? "") contains timing that cannot yet be mapped (\(unsupported.joined(separator: ", "))).")
        }
        var node: SyntaxNode?
        tree.root.forEachNode { if $0.range == block.range { node = $0 } }
        guard let node, node.kind == .sequential,
              block.events.allSatisfy({ index in node.children.contains(where: { $0.range == tree.events[index].range }) }) else {
            throw Failure("\(file.id): the layout track needs a sequential stream of skips.")
        }
        var ends: [LensFraction] = []
        var end = LensFraction.zero
        for bar in bars { end = end + bar.time.wholeNotes; ends.append(end) }
        var bodies = Array(repeating: "", count: bars.count)
        var outputBars = bars.map { Bar(time: $0.time, breakCommand: nil, explicitTime: nil, length: $0.time.wholeNotes) }
        var at = LensFraction.zero
        var cursor = block.range.lowerBound + 1
        var leaves: [SyntaxNode] = []
        node.forEachLeaf { leaves.append($0) }

        func index(at moment: LensFraction) -> Int {
            ends.firstIndex(where: { moment < $0 }) ?? bars.count - 1
        }
        func segment(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            // Commands at a boundary are kept at the end of the preceding
            // measure. Their execution moment is unchanged even after resizing.
            let destination = ends.firstIndex(of: at) ?? index(at: at)
            var edits: [TextEdit] = []
            for leaf in leaves where range.contains(leaf.range.lowerBound) {
                if leaf.kind == .barCheck { edits.append(TextEdit(leaf.range, "")) }
                if leaf.kind == .command, ["\\break", "\\pageBreak"].contains(tree.string(leaf.range)) {
                    guard let boundary = ends.firstIndex(of: at) else {
                        throw Failure("\(file.id): an explicit break at \(at.numerator)/\(at.denominator) falls inside a measure. Its intended boundary must be resolved before migration.")
                    }
                    if sharedBreaks {
                        let command = tree.string(leaf.range)
                        if command == "\\pageBreak" || outputBars[boundary].breakCommand == nil { outputBars[boundary].breakCommand = command }
                        edits.append(TextEdit(leaf.range, ""))
                    }
                }
            }
            let local = edits.map { TextEdit(($0.range.lowerBound - range.lowerBound)..<($0.range.upperBound - range.lowerBound), $0.replacement) }
            bodies[destination] += local.apply(to: tree.string(range))
        }

        for i in block.events {
            let event = tree.events[i]
            try segment(cursor..<event.range.lowerBound)
            var remaining = duration(event, in: tree, context: context)
            if remaining == .zero {
                bodies[ends.firstIndex(of: at) ?? index(at: at)] += tree.string(event.range)
            } else {
                var first = true
                while remaining > .zero {
                    guard at < end else { throw Failure("\(file.id): the layout track extends beyond the score's shared measures.") }
                    let bar = index(at: at)
                    let length = min(remaining, ends[bar] - at)
                    let fraction = length * LensFraction(bars[bar].time.beatType, bars[bar].time.beats)
                    if first, !event.postEvents.isEmpty {
                        bodies[bar] += "<>" + event.postEvents.map { tree.string($0) }.joined() + " "
                    }
                    bodies[bar] += " \\pondsideSpace \\\(name(bar)) #\(fraction.numerator) #\(fraction.denominator) "
                    remaining = remaining - length
                    at = at + length
                    first = false
                }
            }
            cursor = event.range.upperBound
        }
        try segment(cursor..<(block.range.upperBound - 1))
        var output = ""
        for i in bars.indices {
            var body = bodies[i]
            let parsed = SyntaxTree(body)
            var commands: [String] = []
            parsed.root.forEachLeaf { if $0.kind == .command { commands.append(parsed.string($0.range)) } }
            // Retain a source anchor in genuinely empty bars. Timed commands
            // instead use proportional spaces, so their positions follow edits.
            if commands.allSatisfy({ $0 == "\\pondsideSpace" || $0.hasPrefix("\\pondsideBar") }) {
                let slots = spaces(in: parsed, body: parsed.root.range)
                body = slots.enumerated().map { TextEdit($0.element.range, $0.offset == 0 ? "s1*0" : "") }.apply(to: body)
                if slots.isEmpty { body = "s1*0 " + body }
            }
            output += "\n  \\pondsideMeasure \\\(name(i)) {" + body + "\n  } |"
        }
        return Part(file: file.id, edits: [TextEdit((block.range.lowerBound + 1)..<(block.range.upperBound - 1), output + "\n")], bars: outputBars)
    }
}

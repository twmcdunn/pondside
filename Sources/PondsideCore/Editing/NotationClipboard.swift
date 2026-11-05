/// Clipboard notation is self-contained LilyPond with explicit pitches and
/// durations, so it keeps sounding the same in another score or octave mode.
public enum NotationClipboard {
    public static func copy(tree: SyntaxTree, events indices: [Int]) -> String? {
        let selected = Array(Set(indices)).sorted()
        guard let first = selected.first,
              selected.allSatisfy({ tree.events.indices.contains($0) && tree.events[$0].acceptsNoteEntry }),
              let block = LensBlockFinder.block(in: tree, at: tree.events[first].range.lowerBound),
              selected.allSatisfy({ block.events.contains($0) }) else { return nil }
        var context = LensContextScanner.scan(tree, block: block.context)
        let timeline = LensTimeline(tree: tree, block: block, context: &context)
        guard Set(timeline.events.filter { selected.contains($0.sourceEvent) }.map(\.voiceIndex)).count <= 1,
              !selected.contains(where: { context.isGrace(at: tree.events[$0].range.lowerBound) || context.tremolo(at: tree.events[$0].range.lowerBound) != nil }) else { return nil }
        var paired = Set<Int>()
        for (opening, closing) in [("(", ")"), ("\\(", "\\)"), ("[", "]")] {
            var stack: [Range<Int>] = []
            for index in selected {
                for post in tree.events[index].postEvents {
                    let text = tree.string(post)
                    if text == opening { stack.append(post) }
                    if text == closing, let begin = stack.popLast() {
                        paired.insert(begin.lowerBound)
                        paired.insert(post.lowerBound)
                    }
                }
            }
        }
        var result = "\\absolute { "
        var open: [LensTuplet] = []
        for index in selected {
            let event = tree.events[index]
            let tuplets = context.tuplets(at: event.range.lowerBound)
            var shared = 0
            while shared < min(open.count, tuplets.count), open[shared] == tuplets[shared] { shared += 1 }
            for _ in shared..<open.count { result += "} " }
            for tuplet in tuplets.dropFirst(shared) { result += "\\tuplet \(tuplet.actualNotes)/\(tuplet.normalNotes) { " }
            open = tuplets
            var notes = event.notes
            if event.kind == .chordRepeat || event.kind == .repeatedPitch {
                if event.kind == .chordRepeat {
                    notes = tree.events[..<index].last(where: { $0.kind == .chord })?.notes ?? []
                } else if let previous = tree.events[..<index].last(where: { !$0.notes.isEmpty || $0.kind == .chordRepeat }) {
                    notes = previous.kind == .chordRepeat ? (tree.events[..<index].last(where: { $0.kind == .chord })?.notes ?? []) : previous.notes
                }
            }
            switch event.kind {
            case .note, .chord, .chordRepeat, .repeatedPitch:
                guard !notes.isEmpty else { return nil }
                let pitches = notes.map { n in
                    let pitch = tree.notes[n].absolute
                    return PitchLanguage.nederlands.spell(step: pitch.step, alteration: pitch.alteration)
                        + OctaveRules.markText(pitch.octave)
                }
                result += pitches.count > 1 ? "<" + pitches.joined(separator: " ") + ">" : pitches[0]
            case .rest: result += "r"
            case .multiMeasureRest: result += "R"
            case .spacer: result += "s"
            default: return nil
            }
            result += event.effectiveDuration.text
            for post in event.postEvents {
                let text = tree.string(post)
                if ["(", ")", "\\(", "\\)", "[", "]"].contains(text), !paired.contains(post.lowerBound) { continue }
                if text == "~", index == selected.last { continue }
                result += text
            }
            result += " "
        }
        for _ in open { result += "} " }
        return result + "}"
    }
}

extension ScoreEditor {
    /// Inserts clipboard music as one reversible source edit. Absolute pitch
    /// scopes isolate the pasted music; original notes are checked again after
    /// parsing to protect relative references on either side of the insertion.
    public func pasteNotation(_ text: String, after anchor: Int, insertionAt: Int? = nil, parsing: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        guard tree.events.indices.contains(anchor), tree.events[anchor].acceptsNoteEntry else { return nil }
        let incoming = SyntaxTree(text)
        guard incoming.issues.isEmpty,
              let copied = NotationClipboard.copy(tree: incoming, events: Array(incoming.events.indices)) else { return nil }
        let canonical = SyntaxTree(copied)
        let language = tree.events[anchor].language
        let names = canonical.notes.filter { $0.role == .event }.map { note in
            TextEdit(note.name, language.spell(step: note.absolute.step, alteration: note.absolute.alteration))
        }
        let fragment = names.apply(to: copied)
        let at = insertionAt ?? tree.events[anchor].range.upperBound
        guard at >= tree.events[anchor].range.upperBound, at <= tree.bytes.count else { return nil }
        var edits = [TextEdit.insert(" " + fragment + " ", at: at)]
        if let next = tree.events.first(where: { $0.range.lowerBound >= at }), next.explicitDuration == nil,
           incoming.events.last?.effectiveDuration != next.effectiveDuration {
            edits.append(.insert(next.effectiveDuration.text, at: next.durationInsertion))
        }
        let parse = parsing ?? { SyntaxTree($0, language: tree.notes.first?.language ?? tree.events.first?.language ?? .nederlands) }
        var proposed = parse(edits.apply(to: tree.text))
        var originals: [Int: Pitch] = [:]
        for note in tree.notes where note.role == .event {
            let offset = edits.mapOffset(note.name.lowerBound) + (note.name.lowerBound == at ? fragment.utf8.count + 2 : 0)
            if let index = proposed.noteIndex(startingAt: offset) { originals[index] = note.absolute }
        }
        let repairs = ScoreEditor(proposed).rewritePitches(originals)
        proposed = parse(repairs.apply(to: proposed.text))
        // Collapse the composed edits to a single minimal byte replacement;
        // undo restores the user's original spelling and whitespace exactly.
        let before = tree.bytes, after = proposed.bytes
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        var oldEnd = before.count, newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        let insertedEnd = at + fragment.utf8.count + 2
        let anchors = proposed.events.filter { $0.range.lowerBound > at && $0.range.lowerBound < insertedEnd }.map { $0.range.lowerBound }
        return ScoreEdit(name: "Paste Notation", edits: [TextEdit(start..<oldEnd, String(decoding: after[start..<newEnd], as: UTF8.self))], selectionAnchors: anchors)
    }
}

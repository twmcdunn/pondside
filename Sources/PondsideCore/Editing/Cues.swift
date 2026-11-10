/// Electronics cues: `\ecue "12"` (lilypond-electronics-staff), written in a
/// voice of skips at their exact moments, `s4*0\ecue "12"`.
///
/// `q` puts the next cue at the selection's start on the voice the score
/// keeps its cues in (`CueStaves.cueVoice`), like `k` does a collection. A
/// click on a cue's box selects its `\ecue "12"`; ⌫ deletes it, and the
/// zero-length skip that carried it when nothing else rides on that skip.
public struct ScoreCue: Sendable, Hashable {
    /// `\ecue` through its label string.
    public var command: Range<Int>
    /// The label, unquoted ("12").
    public var label: String
    /// What deleting the cue removes: the command, and the `s4*0` carrying
    /// it when the cue is all that skip carries, with one run of spaces.
    public var removal: Range<Int>
}

extension SyntaxTree {
    /// Every `\ecue "…"` (and `\ecueToCaesura "…"`) in the file, in source order.
    public var cues: [ScoreCue] {
        var leaves: [SyntaxNode] = []
        root.forEachLeaf { if !$0.kind.isTrivia { leaves.append($0) } }
        var found: [ScoreCue] = []
        for i in leaves.indices where leaves[i].kind == .command && CueStaves.commands.contains(string(leaves[i].range)) {
            guard i + 1 < leaves.count, leaves[i + 1].kind == .string else { continue }
            let command = leaves[i].range.lowerBound..<leaves[i + 1].range.upperBound
            let label = String(string(leaves[i + 1].range).dropFirst().dropLast())
            found.append(ScoreCue(command: command, label: label, removal: cueRemoval(command, next: leaves[safe: i + 2])))
        }
        return found
    }

    /// The cue whose source contains `offset`.
    public func cue(at offset: Int) -> ScoreCue? {
        cues.first { $0.command.contains(offset) }
    }

    private func cueRemoval(_ command: Range<Int>, next: SyntaxNode?) -> Range<Int> {
        let b = bytes
        func isSpace(_ i: Int) -> Bool { b.indices.contains(i) && (b[i] == 0x20 || b[i] == 0x09) }
        var start = command.lowerBound
        // The skip right before it, `s4*0`, goes too unless something else
        // rides on it after the cue (`\edesc "…"`, a dynamic, a tweak).
        if let carrier = events.last(where: { $0.range.upperBound <= command.lowerBound }),
           carrier.kind == .spacer, carrier.duration.map({ string($0).hasSuffix("*0") }) == true,
           b[carrier.range.upperBound..<command.lowerBound].allSatisfy({ $0 == 0x20 || $0 == 0x09 }),
           carrier.postEvents.allSatisfy({ $0.upperBound <= command.lowerBound }),
           !(next.map { n in
               n.range.lowerBound >= command.upperBound
                   && b[command.upperBound..<n.range.lowerBound].allSatisfy({ $0 == 0x20 || $0 == 0x09 })
                   && (n.kind == .command || n.kind == .direction) && !CueStaves.commands.contains(string(n.range))
                   && events.allSatisfy { $0.range.lowerBound != n.range.lowerBound }
           } ?? false) {
            start = carrier.range.lowerBound
        }
        var lower = start, upper = command.upperBound
        while isSpace(lower - 1) { lower -= 1 }
        if lower < start { return lower..<upper }
        // Nothing before it to join: keep the space after (`c'4\ecue "3" d'`).
        guard start == 0 || b[start - 1] == 0x0A || b[start - 1] == 0x7B else { return start..<upper }
        while isSpace(upper) { upper += 1 }
        return start..<upper
    }
}

extension ScoreEditor {
    /// Deletes a cue (and its empty carrier skip); every other note keeps its pitch.
    public func deleteCue(_ cue: ScoreCue, parse: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        let parse = parse ?? { SyntaxTree($0, language: tree.events.first?.language ?? .nederlands) }
        guard var edit = finishingCollectionEdit([TextEdit(cue.removal, "")], removed: [cue.removal], carrier: nil,
                                                 pitches: [], name: "Delete Cue \(cue.label)", parse: parse) else { return nil }
        // The music before it (else after it) in its voice stays selected.
        let voice = CollectionTimeline.topLevelValue(containing: cue.command.lowerBound, in: tree)
        func inVoice(_ e: Int) -> Bool {
            !cue.removal.contains(tree.events[e].range.lowerBound) && tree.events[e].kind != .lyric
                && voice.map { $0.contains(tree.events[e].range.lowerBound) } ?? true
        }
        let neighbour = tree.events.indices.last { inVoice($0) && tree.events[$0].range.upperBound <= cue.removal.lowerBound }
            ?? tree.events.indices.first { inVoice($0) && tree.events[$0].range.lowerBound >= cue.removal.upperBound }
        if let neighbour { edit.selectionAnchors = [edit.edits.mapOffset(tree.events[neighbour].range.lowerBound)] }
        return edit
    }
}

public enum CueStaves {
    static let commands: Set<String> = ["\\ecue", "\\ecueToCaesura"]

    /// The label after the highest numbered cue in the score's files.
    public static func nextLabel(trees: [SyntaxTree]) -> String {
        String((trees.flatMap(\.cues).compactMap { Int($0.label) }.max() ?? 0) + 1)
    }

    /// Whether the score can engrave a cue: one of its files defines `\ecue`.
    public static func defined(texts: [String]) -> Bool {
        texts.contains { $0.contains("ecue =") || $0.contains("ecue=") }
    }

    /// The voice the score keeps its cues in: the music variable holding the
    /// most; else one named for them (`electronicsCues`); else the staff
    /// the score keeps its collections on. Nil: none.
    public static func cueVoice(trees: [SyntaxTree]) -> CollectionStaves.Voice? {
        let staves = CollectionStaves.voices(trees: trees)
        var best: (voice: CollectionStaves.Voice, count: Int)?
        var named: CollectionStaves.Voice?
        for (f, tree) in trees.enumerated() {
            let cues = tree.cues
            let children = tree.root.children
            for (i, node) in children.enumerated() where node.kind == .assignment {
                guard let name = node.children.first,
                      let value = children[(i + 1)...].first(where: { !$0.kind.isTrivia }),
                      value.kind == .sequential,
                      tree.events.contains(where: { value.range.contains($0.range.lowerBound) && $0.kind != .lyric })
                else { continue }
                let key = tree.string(name.range)
                let staff = staves.first { $0.name == key }
                let voice = CollectionStaves.Voice(staff: staff?.staff ?? -1, file: f, name: key, value: value.range,
                                                   staffFile: staff?.staffFile ?? f, declaration: staff?.declaration ?? value.range)
                let count = cues.filter { value.range.contains($0.command.lowerBound) }.count
                if count > (best?.count ?? 0) { best = (voice, count) }
                if named == nil, key.lowercased().hasSuffix("cues") { named = voice }
            }
        }
        return best?.voice ?? named ?? CollectionStaves.collectionStaff(trees: trees)
    }

    public struct Placement: Sendable {
        /// Edits by file index, each against that file's current text.
        public var edits: [Int: [TextEdit]]
        /// The file the cue is in, and its label.
        public var file: Int
        public var label: String
        /// The moment fell inside a note there: the cue went where it ends.
        public var snapped: Bool
        public var voiceName: String
        /// A cue already stands at this moment in the voice: no edits, this is it.
        public var existing: ScoreCue?
    }

    /// Cue `label` at the moment `offset` (the selection's start) has in
    /// `trees[file]`, in `target`'s music, as `s4*0\ecue "label"`.
    public static func insert(label: String, at offset: Int, file: Int, into target: CollectionStaves.Voice,
                              trees: [SyntaxTree], parse: @escaping (Int, String) -> SyntaxTree) -> Placement? {
        guard trees.indices.contains(file), trees.indices.contains(target.file) else { return nil }
        let root = trees.first
        let destination = trees[target.file]
        guard let here = CollectionTimeline(tree: trees[file], root: root, at: offset)?.moment(at: offset),
              let timeline = CollectionTimeline(tree: destination, root: root, at: target.value.lowerBound + 1) else { return nil }
        if let same = destination.cues.first(where: { target.value.contains($0.command.lowerBound)
            && timeline.moment(at: $0.command.lowerBound) == here }) {
            return Placement(edits: [:], file: target.file, label: same.label, snapped: false, voiceName: target.name, existing: same)
        }
        guard let (spot, snapped) = timeline.spot(at: here) else { return nil }
        let text = "s4*0\\ecue \"\(label)\""
        let (inserted, _, _) = timeline.insertion(of: text, at: spot, timed: true)
        guard let edit = ScoreEditor(destination).finishingCollectionEdit(inserted, removed: [], carrier: nil, pitches: [],
                                                                         name: "Add Cue \(label)",
                                                                         parse: { parse(target.file, $0) }) else { return nil }
        return Placement(edits: [target.file: edit.edits], file: target.file, label: label, snapped: snapped != nil,
                         voiceName: target.name, existing: nil)
    }
}

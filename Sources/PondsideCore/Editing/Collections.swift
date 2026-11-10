/// Pitch collections: `\collection { c' d' fis' a' }` (DESIGN.md §13).
///
/// A collection takes no time. It stands between two events of a voice (or
/// splits a skip) and so is anchored to the moment where it stands; its notes
/// are written without durations and engraved a fixed distance apart by the
/// kit (`pondside-collections.ily`), whatever the spacing around them. Their
/// accidentals come from their pitches alone: sharps and flats are always
/// shown, anything else is natural.
///
/// Edits here are minimal text edits like every other score edit. Placing a
/// collection at a moment uses the voice's own timeline: the managed bars
/// (`\pondsideMeasure`) when the score has them, else the voice read in
/// order. Relative octave chains are kept: every other note keeps its pitch.
public struct ScoreCollection: Sendable, Hashable {
    /// From `\collection` through the closing brace.
    public var command: Range<Int>
    /// Between the braces.
    public var body: Range<Int>
    /// The events and notes inside, in source order.
    public var events: [Int]
    public var notes: [Int]
}

extension SyntaxTree {
    /// Every `\collection { … }` in the file, in source order.
    public var collections: [ScoreCollection] {
        var found: [ScoreCollection] = []
        root.forEachNode { node in
            let children = node.children.filter { !$0.kind.isTrivia }
            for i in children.indices where children[i].kind == .command && string(children[i].range) == "\\collection" {
                guard i + 1 < children.count, children[i + 1].kind == .sequential else { continue }
                let braces = children[i + 1].range
                let body = (braces.lowerBound + 1)..<max(braces.lowerBound + 1, braces.upperBound - 1)
                let inside = events.indices.filter { body.contains(events[$0].range.lowerBound) }
                found.append(ScoreCollection(command: children[i].range.lowerBound..<braces.upperBound, body: body,
                                             events: inside, notes: inside.flatMap { events[$0].notes }))
            }
        }
        return found.sorted { $0.command.lowerBound < $1.command.lowerBound }
    }

    /// The collection whose source contains `offset` (its command, braces or notes).
    public func collection(at offset: Int) -> ScoreCollection? {
        collections.first { $0.command.contains(offset) }
    }

    public func collection(containingEvent index: Int) -> ScoreCollection? {
        guard events.indices.contains(index) else { return nil }
        return collection(at: events[index].range.lowerBound)
    }
}

// MARK: - Where a collection can stand

/// A voice's timeline in whole notes, for placing zero-length music.
struct CollectionTimeline {
    struct Segment {
        var body: Range<Int>
        var start: LensFraction
        /// The managed bar's length; nil for a voice read as one sequence.
        var length: LensFraction?
        var events: [(index: Int, onset: LensFraction, duration: LensFraction, splittable: Bool)]
        var contentEnd: LensFraction
        /// `<< … >>` inside: moments are not a single sequence.
        var split: Bool
    }

    let tree: SyntaxTree
    var segments: [Segment] = []

    /// The timeline of the voice around `offset`. `root` is the score's root
    /// tree: its shared bars give the managed bars' starts and lengths.
    init?(tree: SyntaxTree, root: SyntaxTree?, at offset: Int) {
        self.tree = tree
        let inCollections = tree.collections
        func zero(_ e: Int) -> Bool {
            inCollections.contains { $0.body.contains(tree.events[e].range.lowerBound) }
        }
        func segment(body: Range<Int>, start: LensFraction, length: LensFraction?) -> Segment {
            let context = LensContextScanner.scan(tree, block: body)
            var cursor = LensFraction.zero
            var list: [(Int, LensFraction, LensFraction, Bool)] = []
            for e in tree.events.indices where body.contains(tree.events[e].range.lowerBound) && !zero(e) {
                let event = tree.events[e]
                guard event.kind != .lyric else { continue }
                let d = StructuralEditing.duration(event, in: tree, context: context)
                let splittable = event.kind == .spacer && context.tuplets(at: event.range.lowerBound).isEmpty
                    && context.tremolo(at: event.range.lowerBound) == nil
                list.append((e, cursor, d, splittable))
                cursor = cursor + d
            }
            var split = false
            tree.root.forEachNode { node in
                if node.kind == .simultaneous, body.contains(node.range.lowerBound),
                   list.contains(where: { node.range.contains(tree.events[$0.0].range.lowerBound) }) { split = true }
            }
            return Segment(body: body, start: start, length: length,
                           events: list.map { (index: $0.0, onset: $0.1, duration: $0.2, splittable: $0.3) },
                           contentEnd: cursor, split: split)
        }

        let value = Self.topLevelValue(containing: offset, in: tree)
        let measures = value.map { v in StructuralEditing.measures(in: tree).filter { v.contains($0.body.lowerBound) } } ?? []
        if let root, StructuralEditing.isManaged(root), !measures.isEmpty {
            // The managed bars of this voice: those in the same top-level value.
            let names = StructuralEditing.names(in: root)
            let times = StructuralEditing.times(in: root)
            var starts: [String: LensFraction] = [:]
            var lengths: [String: LensFraction] = [:]
            var position = LensFraction.zero
            for name in names {
                let length = (times[name] ?? .common).wholeNotes
                starts[name] = position
                lengths[name] = length
                position = position + length
            }
            for m in measures {
                guard let start = starts[m.name] else { return nil }
                segments.append(segment(body: m.body, start: start, length: lengths[m.name]))
            }
            segments.sort { $0.start < $1.start }
        } else if let block = LensBlockFinder.block(in: tree, at: offset) {
            segments = [segment(body: block.range, start: .zero, length: nil)]
        } else {
            return nil
        }
        if segments.isEmpty { return nil }
    }

    static func topLevelValue(containing offset: Int, in tree: SyntaxTree) -> Range<Int>? {
        let children = tree.root.children
        for (i, node) in children.enumerated() where node.kind == .assignment {
            guard let value = children[(i + 1)...].first(where: { !$0.kind.isTrivia }) else { continue }
            if value.range.contains(offset) { return value.range }
        }
        return nil
    }

    /// The moment of a zero-length position at `offset` in the voice.
    func moment(at offset: Int) -> LensFraction? {
        guard let s = segments.first(where: { $0.body.contains(offset) || $0.body.upperBound == offset }) else { return nil }
        var t = LensFraction.zero
        for e in s.events where tree.events[e.index].range.lowerBound < offset { t = e.onset + e.duration }
        return s.start + t
    }

    enum Spot {
        /// Before this event, which starts at the moment.
        case before(Int)
        /// Inside this skip, `into` from its start.
        case split(Int, into: LensFraction)
        /// After the segment's music, `gap` later (the bar pads the rest).
        case end(Range<Int>, after: Int?, gap: LensFraction)
    }

    /// Where zero-length music at moment `t` goes. Inside a note or rest it
    /// goes to the next place one can stand instead: `snapped` says where.
    func spot(at t: LensFraction) -> (spot: Spot, snapped: LensFraction?)? {
        guard !(t < .zero) else { return nil }
        let index = segments.lastIndex { !(t < $0.start) } ?? 0
        let s = segments[index]
        if let length = s.length, !(t < s.start + length), index < segments.count - 1 { return nil }
        if s.split { return nil }
        let offset = t - s.start
        for e in s.events {
            if e.onset == offset, e.duration > .zero || tree.events[e.index].kind != .spacer { return (.before(e.index), nil) }
            if e.onset < offset, offset < e.onset + e.duration {
                if e.splittable { return (.split(e.index, into: offset - e.onset), nil) }
                let next = s.start + e.onset + e.duration
                guard let snapped = spot(at: next) else { return nil }
                return (snapped.spot, snapped.snapped ?? next)
            }
        }
        if let length = s.length, length < offset { return nil }
        return (.end(s.body, after: s.events.last?.index, gap: offset - s.contentEnd), nil)
    }

    /// `n` whole notes as a LilyPond duration: `4*49`, `8*3`, `4*7/3`.
    static func durationText(_ f: LensFraction) -> String {
        for base in [1, 2, 4, 8, 16, 32, 64, 128] {
            let n = f * LensFraction(base)
            if n.denominator == 1 { return n.numerator == 1 ? "\(base)" : "\(base)*\(n.numerator)" }
        }
        let q = f * LensFraction(4)
        return "4*\(q.numerator)/\(q.denominator)"
    }

    /// Edits that put `text` (a collection) at `spot`. Returns the edits and
    /// the single edit that carries `text`, with `text`'s place inside it.
    /// `timed`: `text` ends in a written duration (a cue's `s4*0`), so the
    /// event after it keeps its own duration wherever it is inserted.
    func insertion(of text: String, at spot: Spot, timed: Bool = false) -> (edits: [TextEdit], carrier: TextEdit, prefix: Int) {
        let bytes = tree.bytes
        /// The next event at or after `at` must not inherit a new skip's duration.
        let zeroBodies = tree.collections.map(\.body)
        func keepDuration(after at: Int) -> [TextEdit] {
            guard let event = tree.events.first(where: { e in
                e.range.lowerBound >= at && !zeroBodies.contains { $0.contains(e.range.lowerBound) }
            }) else { return [] }
            guard event.explicitDuration == nil, event.kind != .lyric else { return [] }
            return [.insert(event.effectiveDuration.text, at: event.durationInsertion)]
        }
        switch spot {
        case .before(let e):
            let at = tree.events[e].range.lowerBound
            let carrier = TextEdit.insert(text + " ", at: at)
            return ([carrier] + (timed ? keepDuration(after: at) : []), carrier, 0)
        case .split(let e, let into):
            let event = tree.events[e]
            let total = LensFraction(event.effectiveDuration.wholeNotes.0, event.effectiveDuration.wholeNotes.1)
            let rest = total - into
            let first = TextEdit(event.duration ?? event.durationInsertion..<event.durationInsertion, Self.durationText(into))
            let prefix = " "
            let carrier = TextEdit.insert(prefix + text + " s" + Self.durationText(rest), at: event.range.upperBound)
            return ([first, carrier] + keepDuration(after: event.range.upperBound), carrier, prefix.utf8.count)
        case .end(let body, let after, let gap):
            // After the last music and any collections after it (they stand at
            // the music's end, before the new skip); inside the braces.
            var at = after.map { tree.events[$0].range.upperBound }
                ?? (bytes.indices.contains(body.lowerBound) && bytes[body.lowerBound] == 0x7B ? body.lowerBound + 1 : body.lowerBound)
            for c in tree.collections where body.contains(c.command.lowerBound) && c.command.lowerBound >= at {
                at = max(at, c.command.upperBound)
            }
            let lead = " "
            if gap > .zero {
                let skip = "s" + Self.durationText(gap) + " "
                let carrier = TextEdit.insert(lead + skip + text, at: at)
                return ([carrier] + keepDuration(after: at), carrier, lead.utf8.count + skip.utf8.count)
            }
            let carrier = TextEdit.insert(lead + text, at: at)
            return ([carrier] + (timed ? keepDuration(after: at) : []), carrier, lead.utf8.count)
        }
    }
}

/// The moments of a score's events, voice by voice, read as collections are
/// placed (managed bars from the score's start; a voice read in order from
/// its own). For relating an engraving's columns to time.
public struct VoiceMoments {
    private let trees: [SyntaxTree]
    private var timelines: [Int: [CollectionTimeline]] = [:]

    /// `trees[0]` is the root (its shared bars give the managed bars).
    public init(trees: [SyntaxTree]) { self.trees = trees }

    private mutating func timeline(file: Int, offset: Int) -> CollectionTimeline? {
        if let known = timelines[file]?.first(where: { t in t.segments.contains { $0.body.contains(offset) } }) { return known }
        guard trees.indices.contains(file),
              let made = CollectionTimeline(tree: trees[file], root: trees.first, at: offset) else { return nil }
        timelines[file, default: []].append(made)
        return made
    }

    /// The onset and length of event `index` in `trees[file]`; nil inside a
    /// collection or where the voice's moments are not one sequence.
    public mutating func event(file: Int, index: Int) -> (onset: LensFraction, duration: LensFraction)? {
        guard trees.indices.contains(file), trees[file].events.indices.contains(index),
              let t = timeline(file: file, offset: trees[file].events[index].range.lowerBound) else { return nil }
        for s in t.segments where !s.split {
            if let e = s.events.first(where: { $0.index == index }) { return (s.start + e.onset, e.duration) }
        }
        return nil
    }

    /// The moment of a zero-length position (a collection) at `offset`.
    public mutating func moment(file: Int, offset: Int) -> LensFraction? {
        timeline(file: file, offset: offset)?.moment(at: offset)
    }
}

// MARK: - Editing

extension ScoreEditor {
    /// The source of a collection holding `pitches`, spelled in `language`
    /// with absolute octave marks; the caller repairs octaves for its mode.
    static func collectionText(_ pitches: [Pitch], language: PitchLanguage) -> String {
        guard !pitches.isEmpty else { return "\\collection { }" }
        let names = pitches.map { language.spell(step: $0.step, alteration: $0.alteration) + OctaveRules.markText($0.octave) }
        return "\\collection { " + names.joined(separator: " ") + " }"
    }

    /// The collection's span plus one adjacent run of spaces.
    func collectionDeletionRange(_ r: Range<Int>) -> Range<Int> {
        let b = tree.bytes
        var s = r.lowerBound
        while s > 0, b[s - 1] == 0x20 || b[s - 1] == 0x09 { s -= 1 }
        if s < r.lowerBound { return s..<r.upperBound }
        var e = r.upperBound
        while e < b.count, b[e] == 0x20 || b[e] == 0x09 { e += 1 }
        return r.lowerBound..<e
    }

    /// Applies `raw` and restores every other note's pitch (relative chains),
    /// giving the notes of the collection inserted by `carrier` the
    /// `pitches`. Returns one minimal replacement and the inserted
    /// collection's notes in the new text.
    func finishingCollectionEdit(_ raw: [TextEdit], removed: [Range<Int>], carrier: (edit: TextEdit, prefix: Int)?,
                                 pitches: [Pitch], name: String, parse: (String) -> SyntaxTree) -> ScoreEdit? {
        guard raw.isNonOverlapping else { return nil }
        let sorted = raw.normalized
        // An old offset in the new text; an insertion at exactly the offset
        // goes before it (the note after an inserted collection follows it).
        func mapAfter(_ o: Int) -> Int {
            var shift = 0
            for e in sorted {
                if e.range.isEmpty ? e.range.lowerBound <= o : e.range.upperBound <= o { shift += e.delta } else { break }
            }
            return o + shift
        }
        var proposed = parse(raw.apply(to: tree.text))
        var desired: [Int: Pitch] = [:]
        for note in tree.notes where note.role == .event && !removed.contains(where: { $0.contains(note.name.lowerBound) }) {
            if let index = proposed.noteIndex(startingAt: mapAfter(note.name.lowerBound)) { desired[index] = note.absolute }
        }
        var insertedStart: Int?
        if let carrier {
            var shift = 0
            for e in sorted where e != carrier.edit {
                if e.range.upperBound <= carrier.edit.range.lowerBound { shift += e.delta }
            }
            let start = carrier.edit.range.lowerBound + shift + carrier.prefix
            insertedStart = start
            if let made = proposed.collection(at: start) {
                for (n, p) in zip(made.notes, pitches) { desired[n] = p }
            }
        }
        let repairs = ScoreEditor(proposed).rewritePitches(desired)
        proposed = parse(repairs.apply(to: proposed.text))
        let before = tree.bytes, after = proposed.bytes
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] { start += 1 }
        var oldEnd = before.count, newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] { oldEnd -= 1; newEnd -= 1 }
        guard start < oldEnd || start < newEnd else { return nil }
        var anchors: [Int] = []
        if let insertedStart, let made = proposed.collection(at: repairs.mapOffset(insertedStart)) {
            anchors = made.events.map { proposed.events[$0].range.lowerBound }
            if anchors.isEmpty { anchors = [made.command.lowerBound] }
        }
        return ScoreEdit(name: name, edits: [TextEdit(start..<oldEnd, String(decoding: after[start..<newEnd], as: UTF8.self))],
                         selectionAnchors: anchors)
    }

    /// Deletes a collection, every other note keeping its pitch.
    public func deleteCollection(_ collection: ScoreCollection, parse: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        let gone = TextEdit(collectionDeletionRange(collection.command), "")
        let parse = parse ?? { SyntaxTree($0, language: tree.events.first?.language ?? .nederlands) }
        guard var edit = finishingCollectionEdit([gone], removed: [collection.command], carrier: nil, pitches: [],
                                                 name: "Delete Collection", parse: parse) else { return nil }
        // Select the music beside it (before, else after, in its voice), so
        // the selection stays on an event and the lens follows the edit.
        let voice = CollectionTimeline.topLevelValue(containing: collection.command.lowerBound, in: tree)
        func inVoice(_ e: Int) -> Bool {
            !collection.events.contains(e) && voice.map { $0.contains(tree.events[e].range.lowerBound) } ?? true
                && tree.events[e].kind != .lyric
        }
        let neighbour = tree.events.indices.last { inVoice($0) && tree.events[$0].range.upperBound <= collection.command.lowerBound }
            ?? tree.events.indices.first { inVoice($0) && tree.events[$0].range.lowerBound >= collection.command.upperBound }
        if let neighbour {
            edit.selectionAnchors = [edit.edits.mapOffset(tree.events[neighbour].range.lowerBound)]
        }
        return edit
    }

    /// An empty collection straight after `event`, at the moment it ends.
    public func insertCollection(after eventIndex: Int, parse: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        guard tree.events.indices.contains(eventIndex) else { return nil }
        // After a collection's note: after the collection itself.
        let at = tree.collection(containingEvent: eventIndex)?.command.upperBound ?? tree.events[eventIndex].range.upperBound
        let carrier = TextEdit.insert(" \\collection { }", at: at)
        let parse = parse ?? { SyntaxTree($0, language: tree.events[eventIndex].language) }
        return finishingCollectionEdit([carrier], removed: [], carrier: (carrier, 1), pitches: [],
                                       name: "Insert Collection", parse: parse)
    }

    /// An empty collection `later` whole notes after `collection`, in its
    /// voice (`k` at a collection: the next one starts where this one's
    /// engraving ends). A moment inside a note moves to where it ends.
    public func insertCollection(following collection: ScoreCollection, later: LensFraction, root: SyntaxTree?,
                                 parse: ((String) -> SyntaxTree)? = nil) -> (edit: ScoreEdit, snapped: Bool)? {
        guard LensFraction.zero < later,
              let timeline = CollectionTimeline(tree: tree, root: root, at: collection.command.lowerBound),
              let here = timeline.moment(at: collection.command.lowerBound),
              let (spot, snapped) = timeline.spot(at: here + later) else { return nil }
        let language = collection.events.first.map { tree.events[$0].language } ?? tree.events.first?.language ?? .nederlands
        let (raw, carrier, prefix) = timeline.insertion(of: Self.collectionText([], language: language), at: spot)
        guard let edit = finishingCollectionEdit(raw, removed: [], carrier: (carrier, prefix), pitches: [],
                                                 name: "Insert Collection",
                                                 parse: parse ?? { SyntaxTree($0, language: language) }) else { return nil }
        return (edit, snapped != nil)
    }

    /// A note added at the end of an empty collection (the first note
    /// typed into it), octave nearest `near`. Its accidental is only
    /// `accidental` (sharps and flats are written; nothing else is assumed).
    public func insertIntoEmptyCollection(_ collection: ScoreCollection, step: Int, accidental: Int?,
                                          octave explicitOctave: Int? = nil,
                                          parse: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        guard collection.events.isEmpty else { return nil }
        let language = tree.events.last(where: { $0.range.upperBound <= collection.command.lowerBound })?.language
            ?? tree.events.first(where: { $0.range.lowerBound >= collection.command.upperBound })?.language ?? .nederlands
        let near = tree.notes.last { $0.role == .event && $0.name.upperBound <= collection.command.lowerBound }?.absolute
            ?? tree.notes.first { $0.role == .event && $0.name.lowerBound >= collection.command.upperBound }?.absolute
            ?? Pitch(step: 0, octave: 1)
        let octave = explicitOctave ?? OctaveRules.nearestOctave(step: step, to: near)
        let pitch = Pitch(step: step, alteration: accidental ?? 0, octave: octave)
        let carrier = TextEdit(collection.command, Self.collectionText([pitch], language: language))
        let parse = parse ?? { SyntaxTree($0, language: language) }
        return finishingCollectionEdit([carrier], removed: [collection.command], carrier: (carrier, 0), pitches: [pitch],
                                       name: "Insert Note", parse: parse)
    }

    /// The collection the selection means: one whose notes are all among
    /// `events`, or whose command contains `offset`.
    public func selectedCollection(events selected: [Int], offset: Int? = nil) -> ScoreCollection? {
        if let first = selected.first, let c = tree.collection(containingEvent: first),
           selected.allSatisfy({ c.events.contains($0) }) { return c }
        if let offset { return tree.collection(at: offset) }
        return nil
    }

    /// Moves `collection` by `step` whole-note fractions (± the input
    /// duration) in its voice, or copies it there (`copy`, for repeat).
    /// `root` is the score's root tree, for the managed bars.
    public func shiftCollection(_ collection: ScoreCollection, by duration: DurationValue, forward: Bool,
                                copy: Bool, root: SyntaxTree?, parse: ((String) -> SyntaxTree)? = nil) -> (edit: ScoreEdit, snapped: Bool)? {
        shiftCollection(collection, by: LensFraction(duration.wholeNotes.0, duration.wholeNotes.1), forward: forward,
                        copy: copy, root: root, parse: parse)
    }

    /// Moves or copies `collection` by exactly `d` whole notes (for `r`,
    /// the span its engraving takes, `CollectionFollow`).
    public func shiftCollection(_ collection: ScoreCollection, by d: LensFraction, forward: Bool,
                                copy: Bool, root: SyntaxTree?, parse: ((String) -> SyntaxTree)? = nil) -> (edit: ScoreEdit, snapped: Bool)? {
        guard LensFraction.zero < d,
              let timeline = CollectionTimeline(tree: tree, root: root, at: collection.command.lowerBound),
              let here = timeline.moment(at: collection.command.lowerBound) else { return nil }
        let target = forward ? here + d : here - d
        guard let (spot, snapped) = timeline.spot(at: target) else { return nil }
        let pitches = collection.notes.map { tree.notes[$0].absolute }
        let language = collection.events.first.map { tree.events[$0].language } ?? tree.events.first?.language ?? .nederlands
        let text = Self.collectionText(pitches, language: language)
        let (inserted, carrier, prefix) = timeline.insertion(of: text, at: spot)
        var raw = inserted
        var removed: [Range<Int>] = []
        if !copy {
            let gone = collectionDeletionRange(collection.command)
            // Already there: nothing to do.
            if (snapped ?? target) == here { return nil }
            guard !inserted.contains(where: { $0.range.overlaps(gone) || ($0.range.lowerBound > gone.lowerBound && $0.range.lowerBound < gone.upperBound) }) else { return nil }
            raw.append(TextEdit(gone, ""))
            removed.append(collection.command)
        }
        let parse = parse ?? { SyntaxTree($0, language: language) }
        guard let edit = finishingCollectionEdit(raw, removed: removed, carrier: (carrier, prefix), pitches: pitches,
                                                 name: copy ? "Repeat Collection" : "Move Collection", parse: parse) else { return nil }
        return (edit, snapped != nil)
    }

    /// The source of `collection` for the clipboard: self-contained, absolute.
    public static func collectionClipboard(_ collection: ScoreCollection, in tree: SyntaxTree, notes selected: [Int]? = nil) -> String {
        let chosen = selected.map { s in collection.notes.filter { s.contains($0) } } ?? collection.notes
        return "\\absolute { " + collectionText(chosen.map { tree.notes[$0].absolute }, language: .nederlands) + " }"
    }

    /// Pastes a clipboard collection: after `anchor`, or, when the anchor is
    /// itself in a collection, `step` later than that collection.
    public func pasteCollection(_ text: String, after anchor: Int, step: DurationValue, root: SyntaxTree?,
                                parse: ((String) -> SyntaxTree)? = nil) -> ScoreEdit? {
        let incoming = SyntaxTree(text)
        guard incoming.issues.isEmpty, let source = incoming.collections.first, incoming.collections.count == 1,
              incoming.events.indices.allSatisfy({ source.events.contains($0) }),
              tree.events.indices.contains(anchor) else { return nil }
        let pitches = source.notes.map { incoming.notes[$0].absolute }
        let language = tree.events[anchor].language
        let body = Self.collectionText(pitches, language: language)
        if let here = tree.collection(containingEvent: anchor) {
            guard let timeline = CollectionTimeline(tree: tree, root: root, at: here.command.lowerBound),
                  let moment = timeline.moment(at: here.command.lowerBound),
                  let (spot, _) = timeline.spot(at: moment + LensFraction(step.wholeNotes.0, step.wholeNotes.1)) else { return nil }
            let (raw, carrier, prefix) = timeline.insertion(of: body, at: spot)
            return finishingCollectionEdit(raw, removed: [], carrier: (carrier, prefix), pitches: pitches, name: "Paste Collection",
                                           parse: parse ?? { SyntaxTree($0, language: language) })
        }
        let carrier = TextEdit.insert(" " + body, at: tree.events[anchor].range.upperBound)
        return finishingCollectionEdit([carrier], removed: [], carrier: (carrier, 1), pitches: pitches, name: "Paste Collection",
                                       parse: parse ?? { SyntaxTree($0, language: language) })
    }
}

// MARK: - Between staves

/// The score's staves and the voice each one's music starts with, for moving
/// a collection to the staff above or below.
public enum CollectionStaves {
    public struct Voice: Sendable, Hashable {
        public var staff: Int
        /// Index into the files passed in.
        public var file: Int
        public var name: String
        public var value: Range<Int>
        /// The staff's declaration (`\new Staff … { … }`) in `trees[staffFile]`.
        public var staffFile: Int
        public var declaration: Range<Int>
    }

    /// One voice per staff, in score order. `trees[0]` is the root.
    public static func voices(trees: [SyntaxTree]) -> [Voice] {
        let setup = StaffSetup(files: trees.map(\.text))
        var definitions: [String: (file: Int, value: Range<Int>)] = [:]
        for (f, tree) in trees.enumerated() {
            let children = tree.root.children
            for (i, node) in children.enumerated() where node.kind == .assignment {
                guard let name = node.children.first,
                      let value = children[(i + 1)...].first(where: { !$0.kind.isTrivia }),
                      value.kind == .sequential || value.kind == .simultaneous,
                      tree.events.contains(where: { value.range.contains($0.range.lowerBound) && $0.kind != .lyric })
                else { continue }
                let key = tree.string(name.range)
                if definitions[key] == nil { definitions[key] = (f, value.range) }
            }
        }
        var out: [Voice] = []
        for staff in setup.staves {
            let tree = trees[staff.file]
            let end = setup.staves.filter { $0.file == staff.file && $0.offset > staff.offset }.map(\.offset).min() ?? tree.bytes.count
            var found: Voice?
            tree.root.forEachLeaf { leaf in
                guard found == nil, leaf.kind == .command, leaf.range.lowerBound > staff.offset, leaf.range.lowerBound < end else { return }
                let name = String(tree.string(leaf.range).dropFirst())
                if let d = definitions[name] {
                    found = Voice(staff: staff.index, file: d.file, name: name, value: d.value,
                                  staffFile: staff.file, declaration: staff.offset..<end)
                }
            }
            if let found { out.append(found) }
        }
        return out
    }

    /// The staff the score keeps its collections on: the one whose music
    /// holds the most; else one styled for them (`\collectionStyle` in its
    /// declaration); else one named for electronics or tape. Nil: none.
    public static func collectionStaff(trees: [SyntaxTree]) -> Voice? {
        let voices = Self.voices(trees: trees)
        let counts = voices.map { v in trees[v.file].collections.filter { v.value.contains($0.command.lowerBound) }.count }
        if let best = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[best] > 0 { return voices[best] }
        func declaration(_ v: Voice) -> String {
            let tree = trees[v.staffFile]
            return tree.string(v.declaration.clamped(to: 0..<tree.bytes.count))
        }
        if let styled = voices.first(where: { declaration($0).contains("\\collectionStyle") }) { return styled }
        return voices.first { v in
            // Words, not substrings: "select" is not electronics.
            let words = (v.name + " " + declaration(v)).lowercased().split { !$0.isLetter }
            return words.contains { w in w.hasPrefix("elec") || w == "tape" || w.hasPrefix("live") }
        }
    }

    /// An empty collection at the moment `offset` (the selection's start)
    /// has in `trees[file]`, in `target`'s music (`k` with music selected:
    /// the collections staff, `collectionStaff`). A moment inside a note
    /// there moves to where the note ends (`snapped`).
    public static func insertEmpty(at offset: Int, file: Int, into target: Voice, trees: [SyntaxTree],
                                   parse: @escaping (Int, String) -> SyntaxTree) -> Move? {
        guard trees.indices.contains(file), trees.indices.contains(target.file) else { return nil }
        let root = trees.first
        let source = trees[file]
        guard let here = CollectionTimeline(tree: source, root: root, at: offset)?.moment(at: offset),
              let timeline = CollectionTimeline(tree: trees[target.file], root: root, at: target.value.lowerBound + 1),
              let (spot, snapped) = timeline.spot(at: here) else { return nil }
        let destination = trees[target.file]
        let language = destination.events.first { target.value.contains($0.range.lowerBound) }?.language
            ?? source.events.first?.language ?? .nederlands
        let (inserted, carrier, prefix) = timeline.insertion(of: ScoreEditor.collectionText([], language: language), at: spot)
        guard let edit = ScoreEditor(destination).finishingCollectionEdit(inserted, removed: [], carrier: (carrier, prefix),
                                                                         pitches: [], name: "Insert Collection",
                                                                         parse: { parse(target.file, $0) }),
              let first = edit.selectionAnchors.first else { return nil }
        return Move(edits: [target.file: edit.edits], anchor: (target.file, first), snapped: snapped != nil, staffName: target.name)
    }

    public struct Move: Sendable {
        /// Edits by file index, each against that file's current text.
        public var edits: [Int: [TextEdit]]
        /// The moved collection's first byte in the target file's new text.
        public var anchor: (file: Int, offset: Int)
        public var snapped: Bool
        public var staffName: String
    }

    /// Moves the collection at `offset` in `trees[file]` to the same moment
    /// on the staff `direction` (−1 above, +1 below) of its own.
    public static func move(collectionAt offset: Int, file: Int, direction: Int, trees: [SyntaxTree],
                            parse: @escaping (Int, String) -> SyntaxTree) -> Move? {
        guard trees.indices.contains(file), let collection = trees[file].collection(at: offset) else { return nil }
        let voices = Self.voices(trees: trees)
        guard let mine = voices.firstIndex(where: { $0.file == file && $0.value.contains(offset) }) else { return nil }
        let targetIndex = mine + direction
        guard voices.indices.contains(targetIndex) else { return nil }
        let target = voices[targetIndex]
        let root = trees.first
        let source = trees[file]
        guard let here = CollectionTimeline(tree: source, root: root, at: offset)?.moment(at: collection.command.lowerBound),
              let timeline = CollectionTimeline(tree: trees[target.file], root: root, at: target.value.lowerBound + 1),
              let (spot, snapped) = timeline.spot(at: here) else { return nil }
        let pitches = collection.notes.map { source.notes[$0].absolute }
        let destination = trees[target.file]
        let language = destination.events.first { target.value.contains($0.range.lowerBound) }?.language ?? .nederlands
        let text = ScoreEditor.collectionText(pitches, language: language)
        let (inserted, carrier, prefix) = timeline.insertion(of: text, at: spot)
        let sourceEditor = ScoreEditor(source)
        let gone = TextEdit(sourceEditor.collectionDeletionRange(collection.command), "")
        if target.file == file {
            guard let edit = sourceEditor.finishingCollectionEdit(inserted + [gone], removed: [collection.command],
                                                                  carrier: (carrier, prefix), pitches: pitches,
                                                                  name: "Move Collection", parse: { parse(file, $0) }),
                  let first = edit.selectionAnchors.first else { return nil }
            return Move(edits: [file: edit.edits], anchor: (file, first), snapped: snapped != nil, staffName: target.name)
        }
        guard let removal = sourceEditor.finishingCollectionEdit([gone], removed: [collection.command], carrier: nil,
                                                                 pitches: [], name: "Move Collection", parse: { parse(file, $0) }),
              let insertion = ScoreEditor(destination).finishingCollectionEdit(inserted, removed: [], carrier: (carrier, prefix),
                                                                               pitches: pitches, name: "Move Collection",
                                                                               parse: { parse(target.file, $0) }),
              let first = insertion.selectionAnchors.first else { return nil }
        return Move(edits: [file: removal.edits, target.file: insertion.edits], anchor: (target.file, first),
                    snapped: snapped != nil, staffName: target.name)
    }
}

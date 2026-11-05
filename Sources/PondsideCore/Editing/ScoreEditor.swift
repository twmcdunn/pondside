/// The result of a graphical edit: minimal text replacements plus where the
/// selection should land afterwards.
public struct ScoreEdit: Sendable, Hashable {
    public var name: String
    /// Non-overlapping replacements against the current text.
    public var edits: [TextEdit]
    /// Offsets in the *new* text of the events to select after applying.
    public var selectionAnchors: [Int]

    public init(name: String, edits: [TextEdit], selectionAnchors: [Int]) {
        self.name = name
        self.edits = edits.normalized
        self.selectionAnchors = selectionAnchors
    }

    public var isEmpty: Bool { edits.isEmpty }
}

/// Turns musical intentions into minimal text edits that change exactly the
/// characters required — and nothing else.
///
/// "Nothing else" is semantic as well as textual. In `\relative` mode,
/// raising one note an octave would silently move every later note, so the
/// editor rewrites the octave marks of exactly those notes whose reference
/// changed, keeping their absolute pitch. Likewise, giving one note a new
/// duration would change the inherited duration of the next note, so that
/// note gets its old duration written explicitly. The property tests check
/// both invariants on thousands of random edits.
public struct ScoreEditor: Sendable {
    public let tree: SyntaxTree

    public init(_ tree: SyntaxTree) {
        self.tree = tree
    }

    private var notes: [NoteInfo] { tree.notes }
    private var events: [MusicEvent] { tree.events }

    // MARK: Pitch

    public enum PitchMove: Sendable, Hashable {
        /// Diatonic step, honouring the key signature.
        case step(Int)
        /// Chromatic alteration by semitones, keeping the note name.
        case chromatic(Int)
        case octave(Int)
    }

    /// Moves the pitches of the given events (all chord members) or notes.
    public func move(events eventIndices: [Int], extraNotes: [Int] = [], by move: PitchMove) -> ScoreEdit? {
        var targets = Set(extraNotes)
        for e in eventIndices { targets.formUnion(events[e].notes) }
        targets = targets.filter { notes[$0].role == .event }
        guard !targets.isEmpty else { return nil }
        var changes: [Int: Pitch] = [:]
        for i in targets {
            let n = notes[i]
            let p = n.absolute
            switch move {
            case .step(let s):
                let idx = p.diatonicIndex + s
                let step = ((idx % 7) + 7) % 7
                let key = n.event.map { events[$0].key } ?? .cMajor
                changes[i] = Pitch(diatonicIndex: idx, alteration: key.alteration(for: step))
            case .chromatic(let semis):
                let alt = p.alteration + semis * 2
                guard alt >= -4, alt <= 4 else { continue }
                changes[i] = Pitch(step: p.step, alteration: alt, octave: p.octave)
            case .octave(let o):
                changes[i] = Pitch(step: p.step, alteration: p.alteration, octave: p.octave + o)
            }
        }
        guard !changes.isEmpty else { return nil }
        var edits = rewritePitches(changes)
        if case .chromatic = move {
            edits += targets.compactMap { notes[$0].accidentalMark.map { TextEdit($0, "") } }
        }
        let name: String
        switch move {
        case .step: name = "Move Pitch"
        case .chromatic: name = "Change Accidental"
        case .octave: name = "Change Octave"
        }
        let anchors = anchorsAfter(edits, events: eventIndices)
        return ScoreEdit(name: name, edits: edits, selectionAnchors: anchors)
    }

    /// Rewrites the spelled text of every note whose absolute pitch changes
    /// or whose relative reference changes, so that every *other* note keeps
    /// its absolute pitch.
    ///
    /// - Parameters:
    ///   - changes: new absolute pitches.
    ///   - referents: overrides of a note's reference (after insert/delete);
    ///     `.some(nil)` means the implicit `\relative` reference.
    ///   - extraReference: a pitch for a referent index not in `notes`
    ///     (a note being inserted), keyed by -1.
    func rewritePitches(_ changes: [Int: Pitch], referents: [Int: Int?] = [:],
                        insertedPitch: Pitch? = nil, skip: Set<Int> = []) -> [TextEdit] {
        func absolute(_ i: Int) -> Pitch {
            if i == -1, let insertedPitch { return insertedPitch }
            return changes[i] ?? notes[i].absolute
        }
        var affected = Set(changes.keys)
        for i in changes.keys { affected.formUnion(tree.dependents(of: i)) }
        affected.formUnion(referents.keys)
        affected.subtract(skip)

        var edits: [TextEdit] = []
        for i in affected.sorted() {
            let n = notes[i]
            guard n.role == .event || n.role == .chainArgument || changes[i] != nil else { continue }
            let target = absolute(i)
            let referent: Int? = referents[i] ?? n.referent
            let reference: Pitch? = referent.map(absolute)
            var marks = OctaveRules.marks(for: target, mode: n.mode, reference: reference)
            if n.octaveCheck != nil && changes[i] == nil && referents[i] == nil {
                // A note pinned by an octave check keeps its written marks.
                marks = n.writtenMarks
            }
            let name: String
            if target.step == n.writtenStep && target.alteration == n.writtenAlteration {
                name = tree.string(n.name)
            } else {
                name = n.language.spell(step: target.step, alteration: target.alteration, longForm: n.longForm)
            }
            let replacement = name + OctaveRules.markText(marks)
            if replacement != tree.string(n.spelledRange) {
                edits.append(TextEdit(n.spelledRange, replacement))
            }
            if let check = n.octaveCheck, changes[i] != nil {
                let newCheck = "=" + OctaveRules.markText(target.octave)
                if newCheck != tree.string(check) { edits.append(TextEdit(check, newCheck)) }
            }
        }
        return edits
    }

    /// Toggle the requested visible glyph. Removing it restores the pitch
    /// inherited from the key/earlier notes, so an automatic glyph cannot
    /// immediately reappear. Explicit additions use LilyPond's force mark.
    public func toggleAccidental(_ alteration: Int, events selected: [Int], extraNotes: [Int] = [],
                                 structure: SyntaxTree? = nil) -> ScoreEdit? {
        guard [-2, 0, 2].contains(alteration) else { return nil }
        var targets = Set(extraNotes)
        for event in selected { targets.formUnion(events[event].notes) }
        targets = targets.filter { notes[$0].role == .event }
        guard !targets.isEmpty else { return nil }
        let authority = structure ?? tree
        let shared = StructuralEditing.isManaged(authority) ? StructuralEditing.times(in: authority) : [:]
        var timelines: [LensBlock: LensTimeline] = [:]
        var changes: [Int: Pitch] = [:]
        var marks: [TextEdit] = []
        for index in targets.sorted() {
            let note = notes[index]
            guard let event = note.event, let block = LensBlockFinder.block(in: tree, at: note.name.lowerBound) else { continue }
            if timelines[block] == nil {
                var context = LensContextScanner.scan(tree, block: block.context)
                for measure in StructuralEditing.measures(in: tree) where block.range.contains(measure.invocation.lowerBound) {
                    if let time = shared[measure.name] {
                        context.times.append((measure.invocation.lowerBound, time))
                        context.managedMeasures.append((measure.body, time))
                    }
                }
                context.times.sort { $0.offset < $1.offset }
                timelines[block] = LensTimeline(tree: tree, block: block, context: &context)
            }
            guard let timeline = timelines[block], let current = timeline.events.first(where: { $0.sourceEvent == event }) else { continue }
            let prior = timeline.events.filter { $0.voiceIndex == current.voiceIndex && $0.sourceOffset < current.sourceOffset }.sorted { $0.sourceOffset < $1.sourceOffset }
            var key = current.key
            var inherited = key.alteration(for: note.absolute.step)
            var replacementInherited = inherited
            for previous in prior where previous.measureIndex == current.measureIndex {
                if previous.key != key { key = previous.key; inherited = key.alteration(for: note.absolute.step); replacementInherited = inherited }
                for old in previous.notes where notes[old].absolute.step == note.absolute.step && notes[old].absolute.octave == note.absolute.octave {
                    inherited = notes[old].absolute.alteration
                    replacementInherited = changes[old]?.alteration ?? inherited
                }
            }
            if key != current.key { inherited = current.key.alteration(for: note.absolute.step); replacementInherited = inherited }
            let tied = prior.last.map { previous in
                events[previous.sourceEvent].postEvents.contains { tree.string($0) == "~" }
                    && previous.notes.contains { notes[$0].absolute == note.absolute }
            } ?? false
            let visible = note.accidentalMark != nil || (!tied && note.absolute.alteration != inherited)
            let remove = note.absolute.alteration == alteration && visible
            changes[index] = Pitch(step: note.absolute.step, alteration: remove ? replacementInherited : alteration, octave: note.absolute.octave)
            marks.append(TextEdit(note.accidentalMark ?? (note.spelledRange.upperBound..<note.spelledRange.upperBound), remove ? "" : "!"))
        }
        guard !changes.isEmpty else { return nil }
        let edits = rewritePitches(changes) + marks.filter { !$0.range.isEmpty || !$0.replacement.isEmpty }
        return ScoreEdit(name: "Toggle Accidental", edits: edits, selectionAnchors: anchorsAfter(edits, events: selected))
    }

    /// Unarmed entry spells the pitch already in effect at the insertion
    /// point. Managed wrappers define the bar even while unmetered entry
    /// extends it; ordinary source uses the lens's rhythmic/voice timeline.
    private func entryAccidental(step: Int, octave: Int, after anchor: Int, at offset: Int) -> Int {
        let event = events[anchor]
        guard let block = LensBlockFinder.block(in: tree, at: event.range.lowerBound) else {
            return event.key.alteration(for: step)
        }
        let prior: [Int]
        if let measure = StructuralEditing.measures(in: tree).first(where: { $0.body.lowerBound <= offset && offset <= $0.body.upperBound }) {
            prior = block.events.filter { measure.body.contains(events[$0].range.lowerBound) && events[$0].range.upperBound <= offset }
        } else {
            // An insertion before the next wrapper's music must not inherit
            // an accidental from the previous wrapper or a sibling voice.
            var scan = LensContextScanner.scan(tree, block: block.context)
            let timeline = LensTimeline(tree: tree, block: block, context: &scan)
            guard let current = timeline.events.first(where: { $0.sourceEvent == anchor }) else {
                return event.key.alteration(for: step)
            }
            let position = current.onset + current.duration
            guard let measure = timeline.starts.lastIndex(where: { $0 <= position }),
                  position < timeline.starts[measure] + timeline.lengths[measure] else {
                return event.key.alteration(for: step)
            }
            prior = timeline.events.filter {
                $0.voiceIndex == current.voiceIndex && $0.measureIndex == measure && $0.sourceOffset < offset
            }.map(\.sourceEvent)
        }
        var key = event.key
        var alteration = key.alteration(for: step)
        for index in prior {
            if events[index].key != key { key = events[index].key; alteration = key.alteration(for: step) }
            for note in events[index].notes where notes[note].absolute.step == step && notes[note].absolute.octave == octave {
                alteration = notes[note].absolute.alteration
            }
        }
        return key == event.key ? alteration : event.key.alteration(for: step)
    }

    // MARK: Duration

    public func setDuration(events eventIndices: [Int], to duration: DurationValue) -> ScoreEdit? {
        let targets = eventIndices.sorted()
        guard !targets.isEmpty else { return nil }
        var edits: [TextEdit] = []
        // Effective durations after the change, to decide what the next
        // un-written duration would inherit.
        var newEffective: [Int: DurationValue] = [:]
        for e in targets { newEffective[e] = duration }
        for e in targets {
            let ev = events[e]
            if let r = ev.duration {
                if tree.string(r) != duration.text { edits.append(TextEdit(r, duration.text)) }
            } else if ev.effectiveDuration != duration {
                edits.append(.insert(duration.text, at: ev.durationInsertion))
            }
        }
        edits += protectSuccessors(of: targets, newEffective: newEffective)
        guard !edits.isEmpty else { return nil }
        return ScoreEdit(name: "Change Duration", edits: edits, selectionAnchors: anchorsAfter(edits, events: targets))
    }

    public func toggleDot(events eventIndices: [Int]) -> ScoreEdit? {
        guard let first = eventIndices.first else { return nil }
        var d = events[first].effectiveDuration
        d.dots = d.dots == 0 ? 1 : 0
        return setDuration(events: eventIndices, to: d)?.renamed("Toggle Dot")
    }

    /// For each changed event, if the next event inherits its duration and
    /// the inherited value would change, write the old value explicitly.
    private func protectSuccessors(of changed: [Int], newEffective: [Int: DurationValue],
                                   removed: Set<Int> = []) -> [TextEdit] {
        var edits: [TextEdit] = []
        // Walk all events once, simulating inheritance with the changes applied.
        var running = DurationValue.quarter
        for (i, ev) in events.enumerated() {
            if removed.contains(i) { continue }
            if let d = newEffective[i] { running = d; continue }
            if let explicit = ev.explicitDuration { running = explicit; continue }
            if running != ev.effectiveDuration {
                edits.append(.insert(ev.effectiveDuration.text, at: ev.durationInsertion))
                running = ev.effectiveDuration
            }
        }
        return edits
    }

    // MARK: Post-events

    /// Adds `text` (e.g. "(", "~", "-.", "\\fermata") after each event, or
    /// removes it where it is already present.
    public func togglePostEvent(_ text: String, events eventIndices: [Int]) -> ScoreEdit? {
        var edits: [TextEdit] = []
        for e in eventIndices.sorted() {
            let ev = events[e]
            if let existing = ev.postEvents.first(where: { tree.string($0) == text }) {
                // Removing `~` from `c4~8` must not leave `c48`.
                let joins = isWordByte(at: existing.lowerBound - 1) && isWordByte(at: existing.upperBound)
                edits.append(TextEdit(existing, joins ? " " : ""))
            } else {
                let at = ev.range.upperBound
                let separate = isWordByte(text.utf8.last) && isWordByte(at: at)
                edits.append(.insert(separate ? text + " " : text, at: at))
            }
        }
        guard !edits.isEmpty else { return nil }
        return ScoreEdit(name: "Toggle \(text)", edits: edits, selectionAnchors: anchorsAfter(edits, events: eventIndices))
    }

    /// A spanner over the selection: `open` after its first event and
    /// `close` after its last (slur `( )`, beam `[ ]`, hairpin `\< \!`).
    /// When both ends are already there, removes them.
    public func toggleSpan(open: String, close: String, events eventIndices: [Int], name: String) -> ScoreEdit? {
        let sorted = Array(Set(eventIndices)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        func existing(_ text: String, on e: Int) -> Range<Int>? {
            events[e].postEvents.first { tree.string($0) == text }
        }
        func removal(_ r: Range<Int>) -> TextEdit {
            let joins = isWordByte(at: r.lowerBound - 1) && isWordByte(at: r.upperBound)
            return TextEdit(r, joins ? " " : "")
        }
        func addition(_ text: String, after e: Int) -> TextEdit {
            let at = events[e].range.upperBound
            let separate = isWordByte(text.utf8.last) && isWordByte(at: at)
            return .insert(separate ? text + " " : text, at: at)
        }
        var edits: [TextEdit] = []
        if first == last {
            // One note: the opening half alone (a hairpin to the next dynamic).
            edits.append(existing(open, on: first).map(removal) ?? addition(open, after: first))
        } else if let o = existing(open, on: first), let c = existing(close, on: last) {
            edits += [removal(o), removal(c)]
        } else {
            if existing(open, on: first) == nil { edits.append(addition(open, after: first)) }
            if existing(close, on: last) == nil { edits.append(addition(close, after: last)) }
        }
        guard !edits.isEmpty else { return nil }
        return ScoreEdit(name: name, edits: edits, selectionAnchors: anchorsAfter(edits, events: sorted))
    }

    /// Wraps the selected events in `\tuplet n/d { … }`. Refused when the
    /// selection crosses a brace or `<< >>` boundary, or holds the operand
    /// of `\relative`-style commands, since wrapping would change the music.
    public func wrapTuplet(events eventIndices: [Int], numerator: Int = 3, denominator: Int = 2) -> ScoreEdit? {
        guard let first = eventIndices.min(), let last = eventIndices.max() else { return nil }
        let span = events[first].range.lowerBound..<events[last].range.upperBound
        if events[first...last].contains(where: \.isScopeOperand) { return nil }
        var depth = 0
        var balanced = true
        tree.root.forEachLeaf { leaf in
            guard balanced, leaf.range.lowerBound >= span.lowerBound, leaf.range.upperBound <= span.upperBound else { return }
            switch leaf.kind {
            case .openBrace, .openSimultaneous, .embeddedOpen: depth += 1
            case .closeBrace, .closeSimultaneous, .embeddedClose:
                depth -= 1
                if depth < 0 { balanced = false }
            default: break
            }
        }
        guard balanced, depth == 0 else { return nil }
        let edits: [TextEdit] = [
            .insert("\\tuplet \(numerator)/\(denominator) { ", at: span.lowerBound),
            .insert(" }", at: span.upperBound),
        ]
        return ScoreEdit(name: "Tuplet", edits: edits,
                         selectionAnchors: [mapped(span.lowerBound, through: edits, insertionAt: span.lowerBound) + edits[0].replacement.utf8.count])
    }

    // MARK: Commands before a note

    /// Puts `command` (`\clef bass`, `\time 3/4`, `\key d \major`,
    /// `\tempo "Allegro" 4 = 120`) just before `event`. The same command
    /// already standing there (with nothing but other commands between it
    /// and the note) is replaced instead, so choosing again changes it.
    public func insertCommand(_ command: String, before eventIndex: Int, name: String, toggle: Bool = false) -> ScoreEdit? {
        guard events.indices.contains(eventIndex), let keyword = command.split(separator: " ").first else { return nil }
        let start = events[eventIndex].range.lowerBound
        // The run of commands right before the event: back to the previous
        // event, brace or bar check.
        let floor = events.indices.last { $0 < eventIndex }.map { events[$0].range.upperBound } ?? 0
        var leaves: [SyntaxNode] = []
        tree.root.forEachLeaf { leaf in
            if leaf.range.lowerBound >= floor, leaf.range.upperBound <= start { leaves.append(leaf) }
        }
        if let stop = leaves.lastIndex(where: { [.openBrace, .closeBrace, .barCheck, .openSimultaneous, .closeSimultaneous].contains($0.kind) }) {
            leaves.removeFirst(stop + 1)
        }
        let commands = leaves.indices.filter { leaves[$0].kind == .command }
        if let i = commands.last(where: { tree.string(leaves[$0].range) == keyword }) {
            if toggle {
                var end = leaves[i].range.upperBound
                if end < start, tree.bytes[end] == 0x20 { end += 1 }
                let edit = TextEdit(leaves[i].range.lowerBound..<end, "")
                return ScoreEdit(name: name, edits: [edit], selectionAnchors: [mapOld(start, through: [edit])])
            }
            // It runs to the next command or the note, trimmed.
            let next = commands.first { $0 > i }.map { leaves[$0].range.lowerBound } ?? start
            var end = next
            while end > leaves[i].range.lowerBound, [0x20, 0x09, 0x0A].contains(tree.bytes[end - 1]) { end -= 1 }
            let edit = TextEdit(leaves[i].range.lowerBound..<end, command)
            return ScoreEdit(name: name, edits: [edit], selectionAnchors: [mapOld(start, through: [edit])])
        }
        let edit = TextEdit.insert(command + " ", at: start)
        return ScoreEdit(name: name, edits: [edit], selectionAnchors: [start + edit.replacement.utf8.count])
    }

    // MARK: Insert and delete

    /// Inserts a note (step 0…6, or nil for a rest) after `event`, choosing
    /// the octave nearest the previous pitch and the accidental in effect in the measure.
    /// `duration` is the armed duration; nil means "inherit". An explicit
    /// `octave` (mouse entry: the clicked staff position) overrides the
    /// nearest-octave choice.
    /// `insertionAt` advances into a following measure while retaining this
    /// event's pitch reference and restoring downstream relative pitches.
    public func insert(step: Int?, after eventIndex: Int, duration: DurationValue?, octave explicitOctave: Int? = nil, accidental: Int? = nil,
                       insertionAt offset: Int? = nil) -> ScoreEdit? {
        let ev = events[eventIndex]
        let at = offset ?? ev.range.upperBound
        guard at >= ev.range.upperBound, at <= tree.bytes.count else { return nil }
        var edits: [TextEdit] = []
        let inheritedHere = ev.effectiveDuration
        let durationText = offset != nil ? (duration ?? inheritedHere).text : ((duration == nil || duration == inheritedHere) ? "" : duration!.text)
        let newEffective = durationText.isEmpty ? inheritedHere : (duration ?? inheritedHere)

        var noteText: String
        var inserted: Pitch?
        if let step {
            let previous = ev.notes.first.map { notes[$0].absolute } ?? lastPitch(before: ev.range.upperBound)
            let reference = ev.chainRefAfter.map { notes[$0].absolute }
            let octave: Int
            if let explicitOctave {
                octave = explicitOctave
            } else if case .relative = ev.octaveMode {
                octave = OctaveRules.nearestOctave(step: step, to: reference ?? .relativeDefault)
            } else {
                octave = OctaveRules.nearestOctave(step: step, to: previous ?? Pitch(step: 0, octave: 1))
            }
            let alteration = accidental ?? entryAccidental(step: step, octave: octave, after: eventIndex, at: at)
            let pitch = Pitch(step: step, alteration: alteration, octave: octave)
            inserted = pitch
            let marks = OctaveRules.marks(for: pitch, mode: ev.octaveMode, reference: reference)
            noteText = ev.language.spell(step: step, alteration: alteration) + OctaveRules.markText(marks)
                + (accidental == nil ? "" : "!")
        } else {
            noteText = "r"
        }
        noteText += durationText
        // `e(d` → `e( g d`, never `e( gd`.
        let trailing = isWordByte(at: at) || tree.bytes[safe: at] == UInt8(ascii: "<") ? " " : ""
        edits.append(.insert(" " + noteText + trailing, at: at))

        // A bare duration downstream (no pitched event between) would now
        // repeat — or absorb — the inserted note: write out what it sounds.
        var keepsReference = false
        if let bare = events.indices.first(where: { $0 > eventIndex && (events[$0].kind == .repeatedPitch || events[$0].isPitched || events[$0].kind == .chordRepeat) }),
           events[bare].kind == .repeatedPitch, let slot = events[bare].duration?.lowerBound {
            guard let source = events[...eventIndex].last(where: { $0.isPitched || $0.kind == .chordRepeat }) else {
                // Pitchless rhythm (RhythmicStaff): a pitch can't be undone in writing.
                return nil
            }
            if source.kind == .chord || source.kind == .chordRepeat {
                edits.append(.insert("q", at: slot))
            } else if let n = source.notes.first {
                let p = notes[n].absolute
                let reference = inserted ?? ev.chainRefAfter.map { notes[$0].absolute }
                let marks = OctaveRules.marks(for: p, mode: events[bare].octaveMode, reference: reference)
                edits.append(.insert(notes[n].language.spell(step: p.step, alteration: p.alteration, longForm: notes[n].longForm)
                                     + OctaveRules.markText(marks), at: slot))
                // The written-out note carries the old reference pitch, so
                // nothing after it needs compensating.
                keepsReference = true
            }
        }

        // The next note in the chain is now relative to the inserted note.
        if let inserted, case .relative = ev.octaveMode, !keepsReference {
            let ref = ev.chainRefAfter
            var followers = notes.indices.filter {
                notes[$0].referent == ref && notes[$0].mode == .relative && notes[$0].name.lowerBound >= at
            }
            // With no explicit reference, only the scope's first note qualifies.
            if ref == nil { followers = Array(followers.prefix(1)) }
            var overrides: [Int: Int?] = [:]
            for f in followers { overrides[f] = .some(-1) }
            edits += rewritePitches([:], referents: overrides, insertedPitch: inserted)
        }
        // The next event inherits from the inserted one.
        if newEffective != inheritedHere, let next = events.indices.first(where: { $0 > eventIndex }),
           events[next].explicitDuration == nil {
            edits.append(.insert(events[next].effectiveDuration.text, at: events[next].durationInsertion))
        }
        let anchor = at + 1
        return ScoreEdit(name: step == nil ? "Insert Rest" : "Insert Note", edits: edits,
                         selectionAnchors: [mapped(anchor, through: edits, insertionAt: at)])
    }

    /// Deletes events, keeping every other note's pitch and duration.
    public func delete(events eventIndices: [Int]) -> ScoreEdit? {
        let targets = Set(eventIndices)
        guard !targets.isEmpty else { return nil }
        // `\relative c' c1`: removing the operand would hand the scope to
        // whatever comes next.
        if targets.contains(where: { events[$0].isScopeOperand }) { return nil }
        var edits: [TextEdit] = []
        var materialized = false
        for e in targets.sorted() where events[e].kind == .chord {
            // A later `q` repeating this chord must keep sounding it.
            guard let q = events.indices.first(where: { $0 > e && (events[$0].kind == .chord || events[$0].kind == .chordRepeat) }),
                  events[q].kind == .chordRepeat, !targets.contains(q) else { continue }
            // In \relative a written-out chord would join the octave chain.
            if case .relative = events[e].octaveMode { return nil }
            let head = tree.string(events[e].range.lowerBound..<events[e].durationInsertion)
            edits.append(TextEdit(events[q].range.lowerBound..<events[q].durationInsertion, head))
        }
        for e in targets.sorted() {
            edits.append(TextEdit(deletionRange(events[e].range), ""))
            // A bare duration repeating this event keeps sounding it: copy the
            // head verbatim (its marks were relative to the same reference).
            if events[e].isPitched,
               let next = events.indices.first(where: { $0 > e && (events[$0].kind == .repeatedPitch || events[$0].isPitched || events[$0].kind == .chordRepeat) }),
               !targets.contains(next), events[next].kind == .repeatedPitch, let slot = events[next].duration?.lowerBound {
                edits.append(.insert(tree.string(events[e].range.lowerBound..<events[e].durationInsertion), at: slot))
                materialized = true
            }
        }
        if materialized {
            let anchorEvent = anchor(afterDeleting: targets)
            return ScoreEdit(name: "Delete", edits: edits + protectSuccessors(of: [], newEffective: [:], removed: targets),
                             selectionAnchors: anchorEvent.map { [edits.mapOffset(events[$0].range.lowerBound)] } ?? [])
        }
        // Notes relative to a deleted note now refer to its referent.
        let deletedNotes = Set(targets.flatMap { events[$0].notes })
        var overrides: [Int: Int?] = [:]
        for d in deletedNotes {
            for f in tree.dependents(of: d) where !deletedNotes.contains(f) {
                var r = notes[d].referent
                while let x = r, deletedNotes.contains(x) { r = notes[x].referent }
                overrides[f] = .some(r)
            }
        }
        edits += rewritePitches([:], referents: overrides, skip: deletedNotes)
        edits += protectSuccessors(of: [], newEffective: [:], removed: targets)
        let anchorEvent = anchor(afterDeleting: targets)
        let anchors = anchorEvent.map { [mapOld(events[$0].range.lowerBound, through: edits)] } ?? []
        return ScoreEdit(name: "Delete", edits: edits, selectionAnchors: anchors)
    }

    // MARK: Helpers

    /// Where the selection goes after a deletion: the next event of the
    /// same staff's music, else the one before it. Deleting a staff's last
    /// note steps back rather than jumping to the next staff's first.
    private func anchor(afterDeleting targets: Set<Int>) -> Int? {
        guard let first = targets.min(), let last = targets.max() else { return nil }
        let candidates = events.indices.filter { !targets.contains($0) && events[$0].kind != .lyric }
        if let block = LensBlockFinder.block(in: tree, at: events[first].range.lowerBound) {
            let staff = Set(block.events)
            if let next = candidates.first(where: { $0 > last && staff.contains($0) }) { return next }
            if let previous = candidates.last(where: { $0 < first && staff.contains($0) }) { return previous }
        }
        return candidates.first { $0 > last } ?? candidates.last { $0 < first }
    }

    /// Letters, digits and octave marks: bytes that would fuse into one token.
    private func isWordByte(_ c: UInt8?) -> Bool {
        guard let c else { return false }
        return Lexer.isLetter(c) || Lexer.isDigit(c) || c == UInt8(ascii: "'") || c == UInt8(ascii: ",")
    }

    private func isWordByte(at i: Int) -> Bool {
        isWordByte(tree.bytes[safe: i])
    }

    private func lastPitch(before offset: Int) -> Pitch? {
        notes.last { $0.role == .event && $0.name.upperBound <= offset }?.absolute
    }

    /// The event's range plus one adjacent run of spaces, so deletions don't
    /// leave double spaces behind.
    private func deletionRange(_ r: Range<Int>) -> Range<Int> {
        let b = tree.bytes
        var s = r.lowerBound
        while s > 0, b[s - 1] == 0x20 || b[s - 1] == 0x09 { s -= 1 }
        if s < r.lowerBound { return s..<r.upperBound }
        var e = r.upperBound
        while e < b.count, b[e] == 0x20 || b[e] == 0x09 { e += 1 }
        return r.lowerBound..<e
    }

    private func mapOld(_ offset: Int, through edits: [TextEdit]) -> Int {
        edits.mapOffset(offset)
    }

    private func mapped(_ anchor: Int, through edits: [TextEdit], insertionAt at: Int) -> Int {
        // Shift by edits strictly before the insertion point.
        var shift = 0
        for e in edits.normalized where e.range.upperBound <= at && !(e.range.isEmpty && e.range.lowerBound == at) {
            shift += e.delta
        }
        return anchor + shift
    }

    private func anchorsAfter(_ edits: [TextEdit], events eventIndices: [Int]) -> [Int] {
        eventIndices.sorted().map { edits.mapOffset(events[$0].range.lowerBound) }
    }
}

extension ScoreEdit {
    func renamed(_ name: String) -> ScoreEdit {
        var copy = self
        copy.name = name
        return copy
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

public struct LensNote: Sendable, Hashable {
    public var sourceNote: Int
    public var indexInChord: Int
    public var forcesAccidental: Bool

    public init(sourceNote: Int, indexInChord: Int, forcesAccidental: Bool = false) {
        self.sourceNote = sourceNote
        self.indexInChord = indexInChord
        self.forcesAccidental = forcesAccidental
    }
}

/// One source event as the lens draws it.
public struct LensEvent: Sendable, Hashable {
    public var sourceEvent: Int
    /// Measure within the window, from 0.
    public var measureIndex: Int
    /// The MusicXML voice, from 0: a branch of `<< { } \\ { } >>`.
    public var voiceIndex: Int
    /// Position among the measure's chords and rests in this voice. Grace
    /// notes and spacers do not count, except the entry anchor in an empty measure.
    public var ordinal: Int
    public var notes: [LensNote]
    public var isRest: Bool
    public var isGrace: Bool
    public var isTarget: Bool
    /// A note of a `\collection` (a grace too): the lens draws, marks and
    /// steps through these, unlike other graces.
    public var isCollection = false

    public init(
        sourceEvent: Int, measureIndex: Int, voiceIndex: Int, ordinal: Int,
        notes: [LensNote], isRest: Bool, isGrace: Bool, isTarget: Bool
    ) {
        self.sourceEvent = sourceEvent
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.ordinal = ordinal
        self.notes = notes
        self.isRest = isRest
        self.isGrace = isGrace
        self.isTarget = isTarget
    }
}

/// A slur between two events of the window, by index into `events`. Both
/// ends lie in the window and in the same voice; a slur crossing the
/// window's edge is left out.
public struct LensSlur: Sendable, Hashable {
    public var start: Int
    public var end: Int
    /// `\( … \)` rather than `( … )`.
    public var phrasing: Bool

    public init(start: Int, end: Int, phrasing: Bool) {
        self.start = start
        self.end = end
        self.phrasing = phrasing
    }
}

/// A tuplet bracket over events `start...end` of the window (indices into
/// `events`), all in one measure and voice; the innermost tuplet of a
/// nest. The renderer's import drops tuplet brackets.
public struct LensTupletSpan: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var actualNotes: Int
    public var normalNotes: Int
}

/// Tremolo bars on event `event` of the window: across its stem, or with
/// `between`, between it and the next event of its voice.
public struct LensTremoloMark: Sendable, Hashable {
    public var event: Int
    public var bars: Int
    public var between: Bool
}

/// A dynamic (`f`, `mp`, `sfz` …) on event `event` of the window.
public struct LensDynamic: Sendable, Hashable {
    public var event: Int
    public var text: String
}

/// A hairpin from event `start` to the event that ends it (its `\\!`, the
/// next dynamic or the next hairpin), in one voice and inside the window.
public struct LensHairpin: Sendable, Hashable {
    public var start: Int
    public var end: Int
    public var crescendo: Bool
}

/// A hidden chord the MusicXML carries only so that the graces before it
/// (a collection on a staff of skips) have a chord to lean on: the
/// `chordIndex`-th chord or rest of voice `voiceIndex` in measure
/// `measureIndex`. The renderer's import can't read `print-object`, so the
/// adapter hides it.
public struct LensGraceHost: Sendable, Hashable {
    public var measureIndex: Int
    public var voiceIndex: Int
    public var chordIndex: Int
}

/// A collection note the MusicXML writes as a timed note (a 128th taken
/// from the skip after it, so the notes stand in a row as on the page): the
/// `chordIndex`-th chord of voice `voiceIndex` in measure `measureIndex`.
/// The adapter hides its stem and beam.
public struct LensTimedCollectionNote: Sendable, Hashable {
    public var sourceEvent: Int
    public var measureIndex: Int
    public var voiceIndex: Int
    public var chordIndex: Int
}

/// A few measures of one staff around the selection, as MusicXML.
public struct LensScoreWindow: Sendable {
    public var xml: String
    public var label: String?
    public var events: [LensEvent]
    /// The renderer's MusicXML import drops slurs, so they travel separately.
    public var slurs: [LensSlur] = []
    /// The slur the selection is (its `(` or `)` alone), by index into
    /// `slurs`: the lens marks it rather than a note.
    public var selectedSlur: Int?
    /// Tuplet brackets and tremolos, which the import drops too.
    public var tuplets: [LensTupletSpan] = []
    public var tremolos: [LensTremoloMark] = []
    /// Dynamics and hairpins, which the lens's MusicXML leaves out.
    public var dynamics: [LensDynamic] = []
    public var hairpins: [LensHairpin] = []
    /// Hidden chords for graces to lean on, which the renderer must hide.
    public var graceHosts: [LensGraceHost] = []
    /// Collection notes written as timed, stemless notes.
    public var timedCollections: [LensTimedCollectionNote] = []
    /// What the lens can't show faithfully, for a badge.
    public var unsupported: [String]
    public var targetEvent: Int
    /// Every selected event in the window, when the selection spans more
    /// than the target (⇧←/→); the target is always one of them.
    public var selected: [Int] = []
    /// Bar numbers shown, a pickup counting as 0.
    public var bars: ClosedRange<Int>
    /// Whether the last bar shown is the last of the music, so it may end
    /// with a final barline.
    public var reachesEnd: Bool

    public init(xml: String, label: String?, events: [LensEvent], unsupported: [String], targetEvent: Int,
                bars: ClosedRange<Int>, reachesEnd: Bool) {
        self.xml = xml
        self.label = label
        self.events = events
        self.unsupported = unsupported
        self.targetEvent = targetEvent
        self.bars = bars
        self.reachesEnd = reachesEnd
    }

    public var target: LensEvent? { events.first { $0.isTarget } }

    /// Sets `selectedSlur` from the source selection: the slur whose mark
    /// the selection is exactly, else none. A strip reused for a new
    /// selection must call this too, or it keeps the old slur.
    public mutating func updateSelectedSlur(selection: Range<Int>, tree: SyntaxTree) {
        selectedSlur = nil
        guard let mark = ScoreEditor(tree).slurMark(at: selection.lowerBound), mark.range == selection else { return }
        selectedSlur = slurs.firstIndex { slur in
            slur.phrasing == mark.phrasing && events[mark.opens ? slur.start : slur.end].sourceEvent == mark.event
        }
    }

    /// The source event one step after (`step > 0`) or before the target,
    /// for ←→ in the lens. The walk stays in the target's voice and falls
    /// back to the nearest event of any voice where that voice ends; nil at
    /// the edge of the music. Graces are stepped over, except a
    /// collection's notes, which the lens marks.
    public func neighbor(_ step: Int, inserting: Bool = false) -> Int? {
        guard let target, step != 0 else { return nil }
        if inserting && step < 0 { return target.sourceEvent }
        let ahead = events
            .filter { (!$0.isGrace || $0.isCollection) && (step > 0 ? $0.sourceEvent > target.sourceEvent : $0.sourceEvent < target.sourceEvent) }
            .sorted { step > 0 ? $0.sourceEvent < $1.sourceEvent : $0.sourceEvent > $1.sourceEvent }
        return (ahead.first { $0.voiceIndex == target.voiceIndex } ?? ahead.first)?.sourceEvent
    }
}

struct LensMeasuredEvent: Sendable {
    var sourceEvent: Int
    var sourceOffset: Int
    var measureIndex: Int
    var voiceIndex: Int
    var ordinal: Int
    var onset: LensFraction
    var duration: LensFraction
    var writtenDuration: DurationValue
    var notes: [Int]
    var isRest: Bool
    var isMeasureRest: Bool
    var isGrace: Bool
    var isSpacer: Bool
    /// In a `\collection`: drawn as stemless graces, accidentals from the pitch alone.
    var isCollection = false
    /// Tuplets around the event, outermost first.
    var tuplets: [LensTuplet]
    var tupletStart = false
    var tupletStop = false
    /// `\repeat tremolo`: bars, and whether this is the first of a two-note
    /// tremolo (each note written at the pair's whole length, so the pair
    /// is a 2:1 tuplet) or its second.
    var tremolo: (bars: Int, between: Bool, first: Bool)?
    var clef: LensClef
    var key: KeySignature
}

struct LensMeasure: Sendable {
    var index: Int
    /// The bar number, counting a pickup as 0.
    var number: Int
    var start: LensFraction
    var length: LensFraction
    var time: LensTime
    var isPickup: Bool
    var events: [LensMeasuredEvent]
}

public enum LensScoreBuilder {
    /// Divisions per quarter: divisible by 2…10, 12, 14, 16 and so on, so
    /// common tuplets come out exact.
    public static let divisions = 10080

    /// Cheap mode availability: defer timeline/XML work until the lens opens.
    public static func hasTarget(tree: SyntaxTree, selection: Range<Int>) -> Bool {
        guard let target = targetEvent(tree: tree, selection: selection) else { return false }
        return LensBlockFinder.block(in: tree, at: tree.events[target].range.lowerBound) != nil
    }

    public static func build(tree: SyntaxTree, selection: Range<Int>, radius: Int = 4, structure: SyntaxTree? = nil) -> LensScoreWindow? {
        guard let target = targetEvent(tree: tree, selection: selection),
              let block = LensBlockFinder.block(in: tree, at: tree.events[target].range.lowerBound)
        else { return nil }
        var context = LensContextScanner.scan(tree, block: block.context)
        let authority = structure ?? tree
        let sharedTimes = StructuralEditing.isManaged(authority) ? StructuralEditing.times(in: authority) : [:]
        for measure in StructuralEditing.measures(in: tree) where block.range.contains(measure.invocation.lowerBound) {
            if let meter = sharedTimes[measure.name] {
                context.times.append((measure.invocation.lowerBound, meter))
                context.managedMeasures.append((measure.body, meter))
            } else {
                context.flag("shared measure definition unavailable")
            }
        }
        context.times.sort { $0.offset < $1.offset }
        let timeline = LensTimeline(tree: tree, block: block, context: &context)
        guard let targetMeasure = timeline.events.first(where: { $0.sourceEvent == target })?.measureIndex else {
            return nil
        }

        // A range selection (⇧←/→) keeps every event it covers in the
        // window, so the lens can mark the same passage as the score.
        var selected = tree.eventIndices(overlapping: selection).filter { tree.events[$0].kind != .lyric }
        if !selected.contains(target) { selected.append(target) }
        let selectedMeasures = selected.compactMap { event in
            timeline.events.first { $0.sourceEvent == event }?.measureIndex
        }
        let first = max(0, min(targetMeasure - max(0, radius), selectedMeasures.min() ?? targetMeasure))
        let last = min(timeline.starts.count - 1,
                       max(targetMeasure + max(0, radius), selectedMeasures.max() ?? targetMeasure))
        let measures = (first...last).map { index in
            LensMeasure(
                index: index - first,
                number: timeline.hasPickup ? index : index + 1,
                start: timeline.starts[index],
                length: timeline.lengths[index],
                time: timeline.times[index],
                isPickup: index == 0 && timeline.hasPickup,
                events: timeline.events.filter { $0.measureIndex == index }
            )
        }

        var events: [LensEvent] = []
        var tuplets: [LensTupletSpan] = []
        var tremolos: [LensTremoloMark] = []
        var openTuplets: [Int: (tuplet: LensTuplet, measure: Int, span: LensTupletSpan)] = [:]
        func close(_ voice: Int) {
            if let open = openTuplets.removeValue(forKey: voice) { tuplets.append(open.span) }
        }
        for measure in measures {
            for event in measure.events where !event.isSpacer || (measure.events.allSatisfy { $0.isSpacer } && event.sourceEvent == measure.events.first?.sourceEvent) {
                let index = events.count
                if !event.isGrace {
                    let innermost = event.tuplets.last
                    if let innermost, let open = openTuplets[event.voiceIndex], open.tuplet == innermost,
                       open.measure == measure.index {
                        openTuplets[event.voiceIndex]?.span.end = index
                    } else {
                        close(event.voiceIndex)
                        if let innermost {
                            openTuplets[event.voiceIndex] = (innermost, measure.index, LensTupletSpan(
                                start: index, end: index,
                                actualNotes: innermost.actualNotes, normalNotes: innermost.normalNotes))
                        }
                    }
                    if let tremolo = event.tremolo, !tremolo.between || tremolo.first {
                        tremolos.append(LensTremoloMark(event: index, bars: tremolo.bars, between: tremolo.between))
                    }
                }
                var made = LensEvent(
                    sourceEvent: event.sourceEvent,
                    measureIndex: measure.index,
                    voiceIndex: event.voiceIndex,
                    ordinal: event.ordinal,
                    notes: event.notes.enumerated().map { LensNote(sourceNote: $0.element, indexInChord: $0.offset, forcesAccidental: tree.notes[$0.element].accidentalMark != nil) },
                    isRest: event.isRest,
                    isGrace: event.isGrace,
                    isTarget: event.sourceEvent == target
                )
                made.isCollection = event.isCollection
                events.append(made)
            }
        }

        for voice in Array(openTuplets.keys) { close(voice) }
        let slurs = slurPairs(events, tree: tree)

        var writer = MusicXMLLensWriter(tree: tree)
        let xml = writer.write(measures: measures, label: block.label)
        for flag in writer.flags { context.flag(flag) }
        var window = LensScoreWindow(xml: xml, label: block.label, events: events, unsupported: context.badges,
                                     targetEvent: target, bars: measures[0].number...measures[measures.count - 1].number,
                                     reachesEnd: last == timeline.starts.count - 1)
        window.selected = selected
        window.slurs = slurs
        window.updateSelectedSlur(selection: selection, tree: tree)
        window.tuplets = tuplets.sorted { $0.start < $1.start }
        window.tremolos = tremolos
        window.graceHosts = writer.hosts
        window.timedCollections = writer.timedCollections
        (window.dynamics, window.hairpins) = dynamicMarks(events, tree: tree)
        return window
    }

    /// Each dynamic, and each hairpin that ends inside the window: at the
    /// next `\\!`, dynamic or hairpin start in its voice, as in LilyPond.
    /// Grace notes are skipped, as for slurs.
    static func dynamicMarks(_ events: [LensEvent], tree: SyntaxTree) -> ([LensDynamic], [LensHairpin]) {
        var dynamics: [LensDynamic] = []
        var hairpins: [LensHairpin] = []
        var open: [Int: (start: Int, crescendo: Bool)] = [:]
        for (index, event) in events.enumerated() where !event.isGrace {
            let marks = tree.events[event.sourceEvent].postEvents.map { post -> String in
                let text = tree.string(post)
                guard text.count > 1, let first = text.first, "-^_".contains(first) else { return text }
                return String(text.dropFirst())
            }
            let ends = marks.contains { $0 == "\\!" || ScoreEditor.dynamics.contains($0) || ScoreEditor.hairpinStarts.contains($0) }
            if ends, let hairpin = open[event.voiceIndex], hairpin.start != index {
                hairpins.append(LensHairpin(start: hairpin.start, end: index, crescendo: hairpin.crescendo))
                open[event.voiceIndex] = nil
            }
            for mark in marks {
                if ScoreEditor.dynamics.contains(mark) { dynamics.append(LensDynamic(event: index, text: String(mark.dropFirst()))) }
                if ScoreEditor.hairpinStarts.contains(mark) {
                    open[event.voiceIndex] = (index, ["\\<", "\\cr", "\\cresc"].contains(mark))
                }
            }
        }
        return (dynamics, hairpins)
    }

    /// Pairs `(` with the next `)` in the same voice, and `\(` with `\)`.
    /// An end in the same event as a start closes the earlier slur first,
    /// as in `a( b) ( c d)`. Grace notes are skipped: the renderer cannot
    /// anchor a slur on one.
    static func slurPairs(_ events: [LensEvent], tree: SyntaxTree) -> [LensSlur] {
        var open: [Int: [Bool: Int]] = [:]
        var result: [LensSlur] = []
        for (index, event) in events.enumerated() where !event.isGrace {
            let marks = tree.events[event.sourceEvent].postEvents.map { post -> String in
                let text = tree.string(post)
                guard text.count > 1, let first = text.first, "-^_".contains(first) else { return text }
                return String(text.dropFirst())
            }
            for phrasing in [false, true] {
                let (start, end) = phrasing ? ("\\(", "\\)") : ("(", ")")
                if marks.contains(end), let from = open[event.voiceIndex]?[phrasing] {
                    result.append(LensSlur(start: from, end: index, phrasing: phrasing))
                    open[event.voiceIndex]?[phrasing] = nil
                }
                if marks.contains(start) { open[event.voiceIndex, default: [:]][phrasing] = index }
            }
        }
        return result
    }

    private static func targetEvent(tree: SyntaxTree, selection: Range<Int>) -> Int? {
        if let event = tree.eventIndices(overlapping: selection).first(where: { tree.events[$0].kind != .lyric }) {
            return event
        }
        if let event = tree.eventIndex(at: selection.lowerBound), tree.events[event].kind != .lyric {
            return event
        }
        if let note = tree.notes.first(where: { $0.role == .event && $0.spelledRange.overlaps(selection) }) {
            return note.event
        }
        return nil
    }
}

/// When each event of a block sounds, and where its barlines fall.
///
/// Onsets come from the music's structure, not from bar checks: a sequence
/// adds its durations, and every branch of `<< … >>` starts together. Bar
/// lines then follow the meter from the block's start.
struct LensTimeline {
    var events: [LensMeasuredEvent] = []
    var starts: [LensFraction] = []
    var lengths: [LensFraction] = []
    var times: [LensTime] = []
    var hasPickup = false

    private let tree: SyntaxTree
    private let block: LensBlock
    private let context: LensContext
    private var eventAt: [Int: Int] = [:]
    private var onsets: [Int: LensFraction] = [:]
    private var commandOnsets: [Int: LensFraction] = [:]
    /// `<< … >>` in the block, outermost first.
    private var simultaneous: [SyntaxNode] = []

    init(tree: SyntaxTree, block: LensBlock, context: inout LensContext) {
        self.tree = tree
        self.block = block
        self.context = context
        for index in block.events { eventAt[tree.events[index].range.lowerBound] = index }
        _ = walk(tree.root, at: .zero)

        let meters = context.times.compactMap { time in
            commandOnsets[time.offset].map { (onset: $0, time: time.time) }
        }
        func meter(at position: LensFraction) -> LensTime {
            let time = meters.last { !(position < $0.onset) }?.time ?? meters.first?.time ?? .common
            return time.beats > 0 && time.beatType > 0 ? time : .common
        }

        var pickup: LensFraction?
        for partial in context.partials {
            if commandOnsets[partial.offset] == .zero, partial.length > .zero {
                pickup = partial.length
            } else {
                context.flag("partial")
            }
        }
        hasPickup = pickup != nil

        let end = onsets.values.max() ?? .zero
        var position = LensFraction.zero
        var length = pickup ?? meter(at: .zero).wholeNotes
        repeat {
            starts.append(position)
            lengths.append(length)
            times.append(meter(at: position))
            position = position + length
            length = meter(at: position).wholeNotes
        } while !(end < position) && starts.count < 100_000

        measureEvents(&context)
    }

    /// Returns the time after `node`.
    private mutating func walk(_ node: SyntaxNode, at time: LensFraction) -> LensFraction {
        guard node.range.overlaps(block.range) else { return time }
        if node.kind == .event, let index = eventAt[node.range.lowerBound] {
            onsets[index] = time
            return time + length(of: index)
        }
        if node.isLeaf {
            if node.kind == .command { commandOnsets[node.range.lowerBound] = time }
            return time
        }
        if node.kind == .simultaneous, block.range.contains(node.range.lowerBound) {
            simultaneous.append(node)
            var end = time
            for child in node.children { end = max(end, walk(child, at: time)) }
            return end
        }
        var current = time
        for child in node.children { current = walk(child, at: current) }
        if let managed = context.managedMeasures.first(where: { $0.body.lowerBound == node.range.lowerBound + 1 && $0.body.upperBound == node.range.upperBound - 1 }) {
            return time + managed.time.wholeNotes
        }
        return current
    }

    private func length(of index: Int) -> LensFraction {
        let event = tree.events[index]
        guard event.kind != .lyric, !context.isGrace(at: event.range.lowerBound) else { return .zero }
        if StructuralEditing.isEmptyChord(event) { return .zero }
        if event.kind == .spacer && tree.string(event.range) == "s1*0" { return .zero }
        if event.kind == .multiMeasureRest,
           let managed = context.managedMeasures.first(where: { $0.body.contains(event.range.lowerBound) }),
           block.events.filter({ managed.body.contains(tree.events[$0].range.lowerBound) }).count == 1 {
            return managed.time.wholeNotes
        }
        let whole = event.effectiveDuration.wholeNotes
        return LensFraction(whole.0, whole.1) * context.durationFactor(at: event.range.lowerBound)
    }

    private func measure(at onset: LensFraction) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if onset < starts[mid] { high = mid - 1 } else { low = mid }
        }
        return low
    }

    private mutating func measureEvents(_ flags: inout LensContext) {
        var lastNotes: [Int: [Int]] = [:]
        var lastTuplet: [Int: (event: Int, tuplet: LensTuplet)] = [:]
        var ordinals: [Int: (measure: Int, next: Int)] = [:]

        for index in block.events {
            guard let onset = onsets[index] else { continue }
            let event = tree.events[index]
            let offset = event.range.lowerBound
            let voice = voiceIndex(at: offset)
            let measure = measure(at: onset)
            let grace = context.isGrace(at: offset)
            let spacer = event.kind == .spacer

            var notes = event.notes
            if event.kind == .repeatedPitch || event.kind == .chordRepeat { notes = lastNotes[voice] ?? [] }
            if !notes.isEmpty { lastNotes[voice] = notes }

            var ordinal = 0
            if !grace, !spacer {
                let counter = ordinals[voice].flatMap { $0.measure == measure ? $0.next : nil } ?? 0
                ordinal = counter
                ordinals[voice] = (measure, counter + 1)
            }

            let tuplets = context.tuplets(at: offset)
            var written = event.effectiveDuration
            var tremolo: (bars: Int, between: Bool, first: Bool)?
            if !grace, !spacer, let repeated = context.tremolo(at: offset) {
                // LilyPond writes a one-note tremolo at its whole length and
                // each note of a two-note one at the pair's whole length.
                let members = block.events.filter {
                    repeated.body.contains(tree.events[$0].range.lowerBound) && tree.events[$0].kind != .lyric
                        && !context.isGrace(at: tree.events[$0].range.lowerBound)
                }
                let bars = max(1, event.effectiveDuration.log - 2)
                let sounding = length(of: index)
                if members.count <= 2, let value = Self.writtenValue(members.count == 2 ? sounding * LensFraction(2) : sounding) {
                    written = value
                    tremolo = (bars, members.count == 2, members.first == index)
                } else {
                    flags.flag("tremolo")
                }
            }
            var measured = LensMeasuredEvent(
                sourceEvent: index, sourceOffset: offset, measureIndex: measure, voiceIndex: voice,
                ordinal: ordinal, onset: onset, duration: length(of: index),
                writtenDuration: written, notes: notes,
                isRest: event.kind == .rest || event.kind == .multiMeasureRest,
                isMeasureRest: event.kind == .multiMeasureRest, isGrace: grace, isSpacer: spacer,
                tuplets: tuplets, clef: context.clef(at: offset), key: event.key
            )

            measured.isCollection = context.isCollection(at: offset)

            let innermost = tuplets.last
            let previous = lastTuplet[voice]
            if previous?.tuplet != innermost {
                if let previous { events[previous.event].tupletStop = true }
                measured.tupletStart = innermost != nil
            }
            measured.tremolo = tremolo
            events.append(measured)
            lastTuplet[voice] = innermost.map { (events.count - 1, $0) }
        }
        for open in lastTuplet.values { events[open.event].tupletStop = true }
    }

    /// The note value, with up to two dots, that lasts `length` before any
    /// tuplet; nil if none does.
    static func writtenValue(_ length: LensFraction) -> DurationValue? {
        for dots in 0...2 {
            // A value of 1/2^log with `dots` dots lasts (2^(dots+1) - 1) / 2^(log+dots).
            let scaled = length * LensFraction(1 << dots, (1 << (dots + 1)) - 1)
            guard scaled.numerator == 1, scaled.denominator & (scaled.denominator - 1) == 0 else { continue }
            return DurationValue(log: scaled.denominator.trailingZeroBitCount, dots: dots)
        }
        if length.denominator == 1, length.numerator == 2 { return DurationValue(log: -1) }
        return nil
    }

    /// The branch of the outermost `<< … >>` around `offset`.
    private func voiceIndex(at offset: Int) -> Int {
        guard let node = simultaneous.first(where: { $0.range.contains(offset) }) else { return 0 }
        let branches = node.children.filter { $0.kind == .sequential || $0.kind == .simultaneous }
        return branches.firstIndex { $0.range.contains(offset) } ?? 0
    }
}

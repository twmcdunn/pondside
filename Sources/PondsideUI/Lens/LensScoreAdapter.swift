import Foundation
import PondsideCore
import SheetMusicCore
import SheetMusicMusicXML

/// Turns a lens window into the renderer's score. The MusicXML import
/// drops slurs, tuplet brackets and tremolos, but the score model and
/// layout draw all three, so they are attached after parsing; the import
/// also numbers bars and closes the last one as if the window were the
/// whole piece, which is undone here.
enum LensScoreAdapter {
    static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    static func score(for lens: LensScoreWindow) throws -> Score {
        var score = try MusicXMLParser.parse(Data(lens.xml.utf8))
        hideGraceHosts(lens, in: &score)
        preserveWrittenAccidentals(lens, in: &score)
        // Before anything that records element indices (tuplets): each
        // dynamic is a voice element of its own, just before its chord.
        attachDynamics(lens, to: &score)
        trim(&score, reachesEnd: lens.reachesEnd)
        attachSlurs(lens, to: &score)
        attachHairpins(lens, to: &score)
        attachTuplets(lens, to: &score)
        attachTremolos(lens, to: &score)
        return score
    }

    /// The chords written only for a collection's graces to lean on. Before
    /// anything that counts chords: `element(of:)` skips hidden ones.
    static func hideGraceHosts(_ lens: LensScoreWindow, in score: inout Score) {
        for host in lens.graceHosts {
            guard let at = chordElement(host.chordIndex, voice: host.voiceIndex, measure: host.measureIndex, in: lens, score: score)
            else { continue }
            updateChord(in: &score, measure: host.measureIndex, slot: at.slot, index: at.index) { $0.visible = false }
        }
        // A collection drawn as timed notes: stemless and unbeamed, its
        // sharps and flats always shown and no naturals, as the kit draws it.
        for timed in lens.timedCollections {
            guard let at = chordElement(timed.chordIndex, voice: timed.voiceIndex, measure: timed.measureIndex, in: lens, score: score)
            else { continue }
            updateChord(in: &score, measure: timed.measureIndex, slot: at.slot, index: at.index) { chord in
                chord.stemVisible = false
                chord.beamVisible = false
                for n in chord.notes.indices {
                    chord.notes.updateNote(at: n) { note in
                        if note.accidental == .natural { note.accidental = nil }
                        note.accidentalRole = .user
                    }
                }
            }
        }
    }

    /// The `index`-th chord (rests included) of lens voice `voice` in
    /// `measure`, counting the writer's auxiliary chords too.
    private static func chordElement(_ index: Int, voice: Int, measure: Int, in lens: LensScoreWindow, score: Score)
        -> (slot: Int, index: Int)? {
        guard let slot = slot(of: voice, measure: measure, in: lens),
              let measures = score[staff]?.measures, measures.indices.contains(measure),
              measures[measure].voices.indices.contains(slot) else { return nil }
        var seen = 0
        for (at, element) in measures[measure].voices[slot].elements.enumerated() {
            guard case .chord = element else { continue }
            if seen == index { return (slot, at) }
            seen += 1
        }
        return nil
    }

    /// The parsed voice slot of lens voice `voice` in `measure`: the
    /// importer numbers voices by first appearance.
    private static func slot(of voice: Int, measure: Int, in lens: LensScoreWindow) -> Int? {
        Set(lens.events.filter { $0.measureIndex == measure }.map(\.voiceIndex)).sorted().firstIndex(of: voice)
    }

    /// Where a collection's note landed: the grace chord the importer hung
    /// on a chord of its voice (before it, or after the voice's last chord).
    /// Graces keep their order, so the measure's graces in the voice, in
    /// source order, are the voice's grace chords in reading order.
    static func grace(of event: LensEvent, in lens: LensScoreWindow, score: Score) -> GraceNoteID? {
        let timed = Set(lens.timedCollections.map(\.sourceEvent))
        guard event.isGrace, !timed.contains(event.sourceEvent), let measures = score[staff]?.measures, measures.indices.contains(event.measureIndex),
              let slot = slot(of: event.voiceIndex, measure: event.measureIndex, in: lens),
              measures[event.measureIndex].voices.indices.contains(slot) else { return nil }
        let graces = lens.events.filter { $0.isGrace && !timed.contains($0.sourceEvent) && $0.measureIndex == event.measureIndex && $0.voiceIndex == event.voiceIndex }
            .map(\.sourceEvent).sorted()
        guard let wanted = graces.firstIndex(of: event.sourceEvent) else { return nil }
        var seen = 0
        for (index, element) in measures[event.measureIndex].voices[slot].elements.enumerated() {
            guard case let .chord(chord) = element else { continue }
            let parent = VoiceElementID(staff: staff, measureIndex: event.measureIndex, voiceIndex: slot, elementIndex: index)
            for (side, count) in [(GraceNoteID.Side.before, chord.graceNotesBefore.count), (.after, chord.graceNotesAfter.count)] {
                if wanted < seen + count {
                    return GraceNoteID(parent: parent, side: side, graceIndex: wanted - seen, noteIndexInGraceChord: 0)
                }
                seen += count
            }
        }
        return nil
    }

    /// The lens event a clicked grace note belongs to.
    static func event(at grace: GraceNoteID, in lens: LensScoreWindow, score: Score) -> LensEvent? {
        lens.events.first { event in
            guard event.isCollection, let id = self.grace(of: event, in: lens, score: score) else { return false }
            return id.parent == grace.parent && id.side == grace.side && id.graceIndex == grace.graceIndex
        }
    }

    /// Every note of a collection event's grace chord.
    private static func graceItems(of event: LensEvent, in lens: LensScoreWindow, score: Score) -> [ScoreItemID] {
        guard event.isCollection, let id = grace(of: event, in: lens, score: score) else { return [] }
        return event.notes.indices.map {
            .graceNote(GraceNoteID(parent: id.parent, side: id.side, graceIndex: id.graceIndex, noteIndexInGraceChord: $0))
        }
    }

    /// MusicXML import loses LilyPond's !/? display intent. Mark only those
    /// source-forced glyphs as user accidentals; ordinary pitch changes keep
    /// the layout engine's automatic accidental suppression.
    static func preserveWrittenAccidentals(_ lens: LensScoreWindow, in score: inout Score) {
        for event in lens.events where event.notes.contains(where: \.forcesAccidental) {
            guard let at = element(of: event, in: lens, score: score) else { continue }
            updateChord(in: &score, measure: event.measureIndex, slot: at.slot, index: at.index) { chord in
                for note in event.notes where note.forcesAccidental && chord.notes.indices.contains(note.indexInChord) {
                    chord.notes.updateNote(at: note.indexInChord) { $0.accidentalRole = .user }
                }
            }
        }
    }

    /// A window cut from the middle of the music: the renderer would number
    /// its first bar 1 and close its last with a final barline. The footer
    /// carries the real bar numbers instead.
    static func trim(_ score: inout Score, reachesEnd: Bool) {
        guard !score.parts.isEmpty else { return }
        score.parts.updateValue(at: 0) { part in
            guard !part.staves.isEmpty else { return }
            part.staves.updateValue(at: 0) { staff in
                guard !staff.measures.isEmpty else { return }
                staff.measures[0].irregular = true
                guard !reachesEnd else { return }
                let last = staff.measures.count - 1
                guard !staff.measures[last].voices.isEmpty else { return }
                let elements = Array(staff.measures[last].voices[0].elements)
                staff.measures[last].voices[0].elements = IdentifiedArray(elements + [.barLine(BarLine(subtype: nil))])
            }
        }
    }

    /// Where `event` landed in the parsed score: its voice slot and element
    /// index. The importer files clefs, keys and barlines among a voice's
    /// elements and numbers voices by first appearance, so the element is
    /// found by counting chords (a rest is an empty chord) in the voice's
    /// slot, not by trusting indices.
    static func element(of event: LensEvent, in lens: LensScoreWindow, score: Score) -> (slot: Int, index: Int)? {
        if event.isCollection {
            guard let timed = lens.timedCollections.first(where: { $0.sourceEvent == event.sourceEvent }) else { return nil }
            return chordElement(timed.chordIndex, voice: timed.voiceIndex, measure: timed.measureIndex, in: lens, score: score)
        }
        guard !event.isGrace, let measures = score[staff]?.measures,
              measures.indices.contains(event.measureIndex) else { return nil }
        let voicesHere = Set(lens.events.filter { $0.measureIndex == event.measureIndex }.map(\.voiceIndex)).sorted()
        let voices = measures[event.measureIndex].voices
        guard let slot = voicesHere.firstIndex(of: event.voiceIndex), voices.indices.contains(slot) else { return nil }

        // The writer's own chords (hosts, timed collection notes) don't count.
        let auxiliary = Set(lens.graceHosts.filter { $0.measureIndex == event.measureIndex && $0.voiceIndex == event.voiceIndex }.map(\.chordIndex))
            .union(lens.timedCollections.filter { $0.measureIndex == event.measureIndex && $0.voiceIndex == event.voiceIndex }.map(\.chordIndex))
        var seen = 0, chords = -1
        for (index, element) in voices[slot].elements.enumerated() {
            guard case .chord = element else { continue }
            chords += 1
            if auxiliary.contains(chords) { continue }
            if seen == event.ordinal { return (slot, index) }
            seen += 1
        }
        return nil
    }

    /// The lens event whose chord is at `anchor` (a clicked mark's owner).
    static func event(at anchor: VoiceElementID, in lens: LensScoreWindow, score: Score) -> LensEvent? {
        lens.events.first { event in
            guard event.measureIndex == anchor.measureIndex, let at = element(of: event, in: lens, score: score) else { return false }
            return at.slot == anchor.voiceIndex && at.index == anchor.elementIndex
        }
    }

    /// The event a hairpin starts on: the first chord after its own element.
    static func event(afterSpanner anchor: VoiceElementID, in lens: LensScoreWindow, score: Score) -> LensEvent? {
        lens.events.filter { event in
            guard event.measureIndex == anchor.measureIndex, let at = element(of: event, in: lens, score: score) else { return false }
            return at.slot == anchor.voiceIndex && at.index > anchor.elementIndex
        }.min { (element(of: $0, in: lens, score: score)?.index ?? .max) < (element(of: $1, in: lens, score: score)?.index ?? .max) }
    }

    /// The parsed score's address for the lens target.
    static func target(of lens: LensScoreWindow, in score: Score) -> (VoiceElementID, ScoreItemID)? {
        guard let event = lens.target else { return nil }
        if event.isCollection, element(of: event, in: lens, score: score) == nil, let item = graceItems(of: event, in: lens, score: score).first, case let .graceNote(id) = item {
            return (id.parent, item)
        }
        guard let (slot, index, chord) = chord(of: event, in: lens, score: score) else { return nil }
        if chord.notes.isEmpty {
            let rest = RestID(staff: staff, measureIndex: event.measureIndex, voiceIndex: slot, elementIndex: index)
            return (VoiceElementID(rest), .rest(rest))
        }
        let note = NoteID(staff: staff, measureIndex: event.measureIndex, voiceIndex: slot, elementIndex: index,
                          noteIndexInChord: 0)
        return (VoiceElementID(note), .note(note))
    }

    /// Every item the lens selection covers: all the notes of a selected
    /// chord, or its rest. The score and the lens mark the same passage.
    static func items(of lens: LensScoreWindow, in score: Score) -> Set<ScoreItemID> {
        var out = Set<ScoreItemID>()
        for event in lens.events where lens.selected.contains(event.sourceEvent) {
            if event.isCollection, element(of: event, in: lens, score: score) == nil {
                out.formUnion(graceItems(of: event, in: lens, score: score))
                continue
            }
            guard let (slot, index, chord) = chord(of: event, in: lens, score: score) else { continue }
            if chord.notes.isEmpty {
                out.insert(.rest(RestID(staff: staff, measureIndex: event.measureIndex,
                                        voiceIndex: slot, elementIndex: index)))
            } else {
                for n in chord.notes.indices {
                    out.insert(.note(NoteID(staff: staff, measureIndex: event.measureIndex, voiceIndex: slot,
                                            elementIndex: index, noteIndexInChord: n)))
                }
            }
        }
        return out
    }

    /// The parsed chord `event` landed on, with its voice slot and element.
    private static func chord(of event: LensEvent, in lens: LensScoreWindow, score: Score)
        -> (slot: Int, index: Int, chord: SheetMusicCore.Chord)? {
        guard let (slot, index) = element(of: event, in: lens, score: score),
              let measures = score[staff]?.measures, measures.indices.contains(event.measureIndex),
              measures[event.measureIndex].voices.indices.contains(slot),
              case let .chord(chord) = measures[event.measureIndex].voices[slot].elements[index]
        else { return nil }
        return (slot, index, chord)
    }

    /// Dynamics go into the voice just before their chord, where the layout
    /// looks for them (a dynamic on a rest has no anchor and is left out).
    static func attachDynamics(_ lens: LensScoreWindow, to score: inout Score) {
        for mark in lens.dynamics {
            let event = lens.events[mark.event]
            guard !event.notes.isEmpty, let at = element(of: event, in: lens, score: score) else { continue }
            updateVoice(in: &score, measure: event.measureIndex, slot: at.slot) { voice in
                var elements = Array(voice.elements)
                elements.insert(.dynamic(dynamic(for: mark)), at: at.index)
                voice.elements = IdentifiedArray(elements)
            }
        }
    }

    /// A dynamic, or an expression drawn as one: its dynamics in the music
    /// font's glyphs (`<sym>`), its words in the dynamics' italic. The one
    /// being typed and the selected one in the accent colour.
    static func dynamic(for mark: LensDynamic) -> Dynamic {
        let first = mark.elements.lazy.compactMap { e -> String? in if case .dynamic(let d) = e { d } else { nil } }.first
        let subtype = mark.elements.isEmpty ? mark.text : (first ?? "other-dynamics")
        var dynamic = Dynamic(subtype: subtype, velocity: velocity(subtype))
        if mark.elements.count > 1 || first == nil, !mark.elements.isEmpty {
            var content: [PreservedTextMarkup.ContentItem] = []
            for (i, e) in mark.elements.enumerated() {
                if i > 0 { content.append(.characters(" ")) }
                switch e {
                case .dynamic(let d):
                    for letter in d {
                        guard let name = symbolNames[letter] else { continue }
                        content.append(.element(.init(name: "sym", content: [.characters(name)])))
                    }
                case .text(let t):
                    content.append(.characters(t))
                }
            }
            let derived = RichText(content: content).plainText
            dynamic.text = derived
            dynamic.preservedTextMarkup = PreservedTextMarkup(content: content, derivedText: derived)
            dynamic.playsBack = first != nil
        }
        if mark.isPreview || mark.isSelected {
            dynamic.elementProperties.color = ScoreColor(red: 102, green: 194, blue: 181)
        }
        return dynamic
    }

    private static let symbolNames: [Character: String] = [
        "p": "dynamicPiano", "m": "dynamicMezzo", "f": "dynamicForte", "r": "dynamicRinforzando",
        "s": "dynamicSforzando", "z": "dynamicZ", "n": "dynamicNiente",
    ]

    /// MuseScore's velocities for the common dynamics; playback in the lens
    /// is not the score's, so the rest share mezzo-forte's.
    private static func velocity(_ text: String) -> Int {
        ["pppp": 10, "ppp": 16, "pp": 33, "p": 49, "mp": 64, "mf": 80, "f": 96, "ff": 112, "fff": 126, "ffff": 127][text] ?? 80
    }

    static func attachSlurs(_ lens: LensScoreWindow, to score: inout Score) {
        attachSpanners(lens.slurs.map { ($0.start, $0.end, Spanner(kind: .slur, rawType: "Slur")) }, lens: lens, to: &score)
    }

    /// Hairpins are voice elements of their own, just before their start
    /// chord (after its dynamic): the layout collects them only there, not
    /// from a chord's spanners as it does slurs.
    static func attachHairpins(_ lens: LensScoreWindow, to score: inout Score) {
        attachSpanners(lens.hairpins.map { hairpin in
            (hairpin.start, hairpin.end, Spanner(kind: .hairpin, rawType: "HairPin",
                                                 hairpin: .init(subtype: hairpin.crescendo ? .crescendo : .decrescendo)))
        }, lens: lens, to: &score, asVoiceElements: true)
    }

    /// Slurs hang on their start chord, hairpins just before it, with the distance to
    /// their end, in measures plus time from the start chord's place in its
    /// bar, counted the way the layout counts (chord durations, not
    /// `<forward>` gaps).
    private static func attachSpanners(_ spans: [(start: Int, end: Int, spanner: Spanner)], lens: LensScoreWindow,
                                       to score: inout Score, asVoiceElements: Bool = false) {
        guard !spans.isEmpty, let staffValue = score[staff] else { return }
        let durations = score.effectiveMeasureDurations()
        let division = score.division

        func tick(measure: Int, slot: Int, before index: Int) -> Int {
            let length = durations.indices.contains(measure) ? durations[measure] : Fraction(numerator: 1, denominator: 1)
            var ticks = 0
            for element in staffValue.measures[measure].voices[slot].elements.prefix(index) {
                switch element {
                case let .chord(chord): ticks += chord.duration.resolved(in: length).ticks(division: division)
                case let .locationShift(delta): ticks += delta.ticks(division: division)
                default: break
                }
            }
            return ticks
        }

        for span in spans {
            let first = lens.events[span.start], last = lens.events[span.end]
            guard let start = element(of: first, in: lens, score: score),
                  let end = element(of: last, in: lens, score: score),
                  start.slot == end.slot else { continue }
            let distance = tick(measure: last.measureIndex, slot: end.slot, before: end.index)
                - tick(measure: first.measureIndex, slot: start.slot, before: start.index)
            var spanner = span.spanner
            spanner.nextMeasuresOffset = last.measureIndex - first.measureIndex
            spanner.nextFractionsOffset = Fraction(numerator: distance, denominator: 4 * division)
            if asVoiceElements {
                updateVoice(in: &score, measure: first.measureIndex, slot: start.slot) { voice in
                    var elements = Array(voice.elements)
                    elements.insert(.spanner(spanner), at: start.index)
                    voice.elements = IdentifiedArray(elements)
                }
                continue
            }
            updateChord(in: &score, measure: first.measureIndex, slot: start.slot, index: start.index) {
                $0.spanners.append(spanner)
            }
        }
    }

    /// The renderer's address for lens slur `index`: its start chord and its
    /// place among the slurs `attachSlurs` hung there (nil if it was left
    /// out, its ends in different voice slots).
    static func slurID(of index: Int, in lens: LensScoreWindow, score: Score) -> SlurID? {
        func attached(_ slur: LensSlur) -> (slot: Int, index: Int)? {
            guard let start = element(of: lens.events[slur.start], in: lens, score: score),
                  let end = element(of: lens.events[slur.end], in: lens, score: score),
                  start.slot == end.slot else { return nil }
            return start
        }
        guard lens.slurs.indices.contains(index) else { return nil }
        let slur = lens.slurs[index]
        guard let start = attached(slur) else { return nil }
        let ordinal = lens.slurs[..<index].filter { $0.start == slur.start && attached($0) != nil }.count
        let anchor = VoiceElementID(staff: staff, measureIndex: lens.events[slur.start].measureIndex,
                                    voiceIndex: start.slot, elementIndex: start.index)
        return .chord(anchor: anchor, ordinal: ordinal)
    }

    /// The lens slur the renderer drew as `id`.
    static func slur(for id: SlurID, in lens: LensScoreWindow, score: Score) -> LensSlur? {
        lens.slurs.indices.first { slurID(of: $0, in: lens, score: score) == id }.map { lens.slurs[$0] }
    }

    /// Tuplet brackets and numbers, from each span's first to last chord.
    static func attachTuplets(_ lens: LensScoreWindow, to score: inout Score) {
        for span in lens.tuplets {
            let first = lens.events[span.start], last = lens.events[span.end]
            guard first.measureIndex == last.measureIndex,
                  let start = element(of: first, in: lens, score: score),
                  let end = element(of: last, in: lens, score: score),
                  start.slot == end.slot, start.index <= end.index else { continue }
            let tuplet = Tuplet(normalNotes: span.normalNotes, actualNotes: span.actualNotes,
                                startIndex: start.index, endIndex: end.index)
            updateVoice(in: &score, measure: first.measureIndex, slot: start.slot) {
                $0.tuplets = IdentifiedArray(Array($0.tuplets) + [tuplet])
            }
        }
    }

    /// Tremolo bars; a two-note tremolo is held by its first chord, and the
    /// layout pairs it with the next chord of the voice. The renderer draws
    /// heads from the sounding value, so a whole-note pair (two halves)
    /// shows as half notes; written heads need the fork
    /// (docs/SHEET_MUSIC_FORK_PLAN.md).
    static func attachTremolos(_ lens: LensScoreWindow, to score: inout Score) {
        for mark in lens.tremolos {
            let event = lens.events[mark.event]
            guard let subtype = Tremolo.Subtype(rawValue: UInt8(min(4, max(1, mark.bars)))),
                  let at = element(of: event, in: lens, score: score) else { continue }
            updateChord(in: &score, measure: event.measureIndex, slot: at.slot, index: at.index) {
                $0.tremolo = Tremolo(subtype: subtype, span: mark.between ? .between : .single)
            }
        }
    }

    private static func updateVoice(in score: inout Score, measure: Int, slot: Int, _ body: (inout Voice) -> Void) {
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                body(&staff.measures[measure].voices[slot])
            }
        }
    }

    private static func updateChord(in score: inout Score, measure: Int, slot: Int, index: Int,
                                    _ body: (inout SheetMusicCore.Chord) -> Void) {
        updateVoice(in: &score, measure: measure, slot: slot) { voice in
            voice.elements.updateValue(at: index) { element in
                guard case var .chord(chord) = element else { return }
                body(&chord)
                element = .chord(chord)
            }
        }
    }
}

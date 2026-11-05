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
        preserveWrittenAccidentals(lens, in: &score)
        trim(&score, reachesEnd: lens.reachesEnd)
        attachSlurs(lens, to: &score)
        attachTuplets(lens, to: &score)
        attachTremolos(lens, to: &score)
        return score
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
        guard !event.isGrace, let measures = score[staff]?.measures,
              measures.indices.contains(event.measureIndex) else { return nil }
        let voicesHere = Set(lens.events.filter { $0.measureIndex == event.measureIndex }.map(\.voiceIndex)).sorted()
        let voices = measures[event.measureIndex].voices
        guard let slot = voicesHere.firstIndex(of: event.voiceIndex), voices.indices.contains(slot) else { return nil }

        var seen = 0
        for (index, element) in voices[slot].elements.enumerated() {
            guard case .chord = element else { continue }
            if seen == event.ordinal { return (slot, index) }
            seen += 1
        }
        return nil
    }

    /// The parsed score's address for the lens target.
    static func target(of lens: LensScoreWindow, in score: Score) -> (VoiceElementID, ScoreItemID)? {
        guard let event = lens.target, let (slot, index, chord) = chord(of: event, in: lens, score: score)
        else { return nil }
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

    /// Slurs hang on their start chord with the distance to their end, in
    /// measures plus time from the start chord's place in its bar, counted
    /// the way the layout counts (chord durations, not `<forward>` gaps).
    static func attachSlurs(_ lens: LensScoreWindow, to score: inout Score) {
        guard !lens.slurs.isEmpty, let staffValue = score[staff] else { return }
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

        for slur in lens.slurs {
            let first = lens.events[slur.start], last = lens.events[slur.end]
            guard let start = element(of: first, in: lens, score: score),
                  let end = element(of: last, in: lens, score: score),
                  start.slot == end.slot else { continue }
            let distance = tick(measure: last.measureIndex, slot: end.slot, before: end.index)
                - tick(measure: first.measureIndex, slot: start.slot, before: start.index)
            let spanner = Spanner(kind: .slur, rawType: "Slur",
                                  nextMeasuresOffset: last.measureIndex - first.measureIndex,
                                  nextFractionsOffset: Fraction(numerator: distance, denominator: 4 * division))
            updateChord(in: &score, measure: first.measureIndex, slot: start.slot, index: start.index) {
                $0.spanners.append(spanner)
            }
        }
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

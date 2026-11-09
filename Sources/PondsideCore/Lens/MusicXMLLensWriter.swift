/// One staff of lens measures as MusicXML 4.0 partwise, in memory.
///
/// The writer spells out what a MusicXML reader would otherwise have to
/// infer: accidentals follow LilyPond's default rule (a key or earlier
/// accidental in the same measure and octave holds; tied notes repeat
/// none), and each voice is placed with `<backup>`/`<forward>` from its
/// onsets. Beams are left to the renderer.
struct MusicXMLLensWriter {
    private struct PitchKey: Hashable {
        var step: Int
        var octave: Int
    }

    private struct VoiceState {
        var ties: Set<Pitch> = []
        var slurOpen = false
    }

    let tree: SyntaxTree
    /// What the output could not represent, for the badge.
    private(set) var flags: [String] = []
    /// The hidden chords written for graces with no chord to lean on.
    private(set) var hosts: [LensGraceHost] = []
    /// The collection notes written as stemless timed notes.
    private(set) var timedCollections: [LensTimedCollectionNote] = []
    /// What each of those takes from the skip after its collection.
    static let collectionSliver = LensFraction(1, 128)
    private var voices: [Int: VoiceState] = [:]

    init(tree: SyntaxTree) {
        self.tree = tree
    }

    mutating func write(measures: [LensMeasure], label: String?) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>\(escape(label ?? "Staff"))</part-name></score-part>
          </part-list>
          <part id="P1">

        """
        var previousTime: LensTime?
        var previousClef: LensClef?
        var previousKey: KeySignature?

        for measure in measures {
            let first = measure.events.first { !$0.isSpacer } ?? measure.events.first
            let clef = first?.clef ?? previousClef ?? .treble
            let key = first?.key ?? previousKey ?? .cMajor
            out += "    <measure number=\"\(measure.number)\"\(measure.isPickup ? " implicit=\"yes\"" : "")>\n"
            out += attributes(first: previousTime == nil, time: measure.time, clef: clef, key: key,
                              previousTime: previousTime, previousClef: previousClef, previousKey: previousKey)
            previousTime = measure.time
            previousClef = clef
            previousKey = key

            let sounding = measure.events.filter { !$0.isSpacer }
            if sounding.isEmpty {
                out += "      <note><rest measure=\"yes\"/><duration>\(units(measure.length))</duration><voice>1</voice></note>\n"
            }

            let voiceIndices = Set(sounding.map(\.voiceIndex)).sorted()
            for (position, voice) in voiceIndices.enumerated() {
                var accidentals: [PitchKey: Int] = [:]
                var clefInVoice = clef
                var cursor = measure.start
                // How far the voice's output has got: past `cursor` while a
                // collection's notes take a sliver of the skip after them.
                var written = measure.start
                // Graces (or a collection) written since the voice's last
                // chord, so the next gap is a hidden chord; and how many
                // chords (rests included) the voice has had in this measure.
                var waitingGraces = false
                var chords = 0
                let events = measure.events.filter { $0.voiceIndex == voice }.sorted { $0.sourceOffset < $1.sourceOffset }
                // In a bar with a collection every skip is a hidden chord, so
                // each collection stands at its moment, not packed together.
                let holdsCollection = events.contains(where: \.isCollection)
                // Time a collection took from the rest right after it.
                var borrowed = LensFraction.zero
                func advance(to time: LensFraction) {
                    guard written < time else { return }
                    if waitingGraces || holdsCollection {
                        out += host(time - written, measure: measure.index, voice: voice, chords: &chords, key: key)
                        waitingGraces = false
                    } else {
                        out += "      <forward><duration>\(units(time - written))</duration><voice>\(voice + 1)</voice></forward>\n"
                    }
                    written = time
                }
                let end = measure.start + measure.length
                var timedRun = 0
                for (eventIndex, event) in events.enumerated() {
                    advance(to: event.onset)
                    if cursor < event.onset { cursor = event.onset }
                    if position == 0, event.clef != clefInVoice {
                        out += "      <attributes>\(clefXML(event.clef))</attributes>\n"
                        clefInVoice = event.clef
                    }
                    if event.isSpacer {
                        advance(to: cursor + event.duration)
                    } else if event.isMeasureRest {
                        out += "      <note><rest measure=\"yes\"/><duration>\(units(measure.length))</duration><voice>\(voice + 1)</voice></note>\n"
                        chords += 1
                        waitingGraces = false
                        cursor = cursor + measure.length
                        written = max(written, cursor)
                        continue
                    } else {
                        if event.isCollection, timedRun == 0 {
                            // The collection's notes, and the time before the
                            // voice's next note (or the bar's end): with room
                            // for a sliver each, they are drawn as stemless
                            // notes in a row, as on the page; else as graces.
                            let run = events[eventIndex...].prefix { $0.isCollection && $0.onset == event.onset }
                            let following = events[(eventIndex + run.count)...].first { !$0.isSpacer }
                            let needed = Self.collectionSliver * LensFraction(run.count)
                            var room = (following?.onset ?? end) - max(written, event.onset)
                            // A rest right after it lends the time (the
                            // renderer hangs graces on notes only).
                            if let following, following.isRest, !following.isMeasureRest, !following.isGrace,
                               following.onset == event.onset, room < needed, needed < following.duration {
                                borrowed = needed
                                room = needed
                            }
                            if !(room < needed) { timedRun = run.count }
                        }
                        let timed = timedRun > 0
                        if timed {
                            timedRun -= 1
                            timedCollections.append(LensTimedCollectionNote(
                                sourceEvent: event.sourceEvent, measureIndex: measure.index, voiceIndex: voice, chordIndex: chords))
                        }
                        let lent = event.isRest && !event.isGrace ? borrowed : .zero
                        if event.isRest && !event.isGrace { borrowed = .zero }
                        let text = note(event, voice: voice, key: key, accidentals: &accidentals, timed: timed, lent: lent)
                        out += text
                        if timed {
                            chords += 1
                            written = written + Self.collectionSliver
                            // The skip after it as a hidden chord too, so the
                            // next collection stands at its own moment.
                            if timedRun == 0 { waitingGraces = true }
                        } else if !text.isEmpty {
                            if event.isGrace {
                                waitingGraces = true
                            } else {
                                chords += 1
                                waitingGraces = false
                            }
                        }
                        if !event.isGrace { written = max(written, cursor + event.duration) }
                        if LensFraction.zero < lent { waitingGraces = false }
                    }
                    cursor = cursor + event.duration
                }
                if waitingGraces { advance(to: end) }
                cursor = max(cursor, written)
                if position + 1 < voiceIndices.count, measure.start < cursor {
                    out += "      <backup><duration>\(units(cursor - measure.start))</duration></backup>\n"
                }
            }
            out += "    </measure>\n"
        }
        out += "  </part>\n</score-partwise>\n"
        return out
    }

    /// A hidden chord of `length` (or of the longest plain value inside it,
    /// the rest as a forward) for the graces just written to lean on. The
    /// renderer drops graces with no chord after them in their voice, as
    /// MuseScore does, so a `\\collection` on a staff of skips would vanish.
    /// Its pitch takes the key's alteration, so it changes no accidental.
    private mutating func host(
        _ length: LensFraction, measure: Int, voice: Int, chords: inout Int, key: KeySignature
    ) -> String {
        guard let log = (0...7).first(where: { !(length < LensFraction(1, 1 << $0)) }) else {
            return "      <forward><duration>\(units(length))</duration><voice>\(voice + 1)</voice></forward>\n"
        }
        let value = LensFraction(1, 1 << log)
        hosts.append(LensGraceHost(measureIndex: measure, voiceIndex: voice, chordIndex: chords))
        chords += 1
        let alteration = key.alteration(for: 6)
        var out = "      <note><pitch><step>B</step>"
        if alteration != 0 { out += "<alter>\(alterText(alteration))</alter>" }
        out += "<octave>4</octave></pitch><duration>\(units(value))</duration><voice>\(voice + 1)</voice>"
        out += "<type>\(typeName(log))</type><stem>none</stem></note>\n"
        if value < length {
            out += "      <forward><duration>\(units(length - value))</duration><voice>\(voice + 1)</voice></forward>\n"
        }
        return out
    }

    private mutating func note(
        _ event: LensMeasuredEvent, voice: Int, key: KeySignature, accidentals: inout [PitchKey: Int], timed: Bool = false,
        lent: LensFraction = .zero
    ) -> String {
        let post = event.isGrace ? [] : tree.events[event.sourceEvent].postEvents.map { normalized(tree.string($0)) }
        var state = voices[voice, default: VoiceState()]
        defer { voices[voice] = state }

        var common = timing(event, voice: voice)
        if timed { common = ("<duration>\(units(Self.collectionSliver))</duration>", "<type>128th</type>", "") }
        // A rest that lent a collection its time: by length alone, since a
        // type would give it back.
        if LensFraction.zero < lent { common = ("<duration>\(units(event.duration - lent))</duration>", "", "") }
        var marks = notations(event, post: post, state: &state)

        guard !event.notes.isEmpty else {
            state.ties = []
            if event.isRest { return "      <note><rest/>\(common.duration)<voice>\(voice + 1)</voice>\(common.type)\(marks)</note>\n" }
            return ""
        }

        var out = ""
        let tieStarts = post.contains("~")
        var nextTies: Set<Pitch> = []
        for (index, noteIndex) in event.notes.enumerated() {
            let pitch = tree.notes[noteIndex].absolute
            let tiedIn = state.ties.contains(pitch)
            if tieStarts { nextTies.insert(pitch) }
            if pitch.alteration % 2 != 0 { flag("quarter tones") }

            let slot = PitchKey(step: pitch.step, octave: pitch.octave)
            let accidental: String?
            if event.isCollection {
                // A collection's sharps and flats always show; it neither takes
                // nor leaves accidentals for the music around it.
                accidental = pitch.alteration != 0 ? accidentalName(pitch.alteration) : nil
            } else {
                let current = accidentals[slot] ?? key.alteration(for: pitch.step)
                let forced = tree.notes[noteIndex].accidentalMark != nil
                accidental = forced || (!tiedIn && pitch.alteration != current) ? accidentalName(pitch.alteration) : nil
                accidentals[slot] = pitch.alteration
            }

            out += "      <note>"
            if event.isGrace && !timed { out += "<grace/>" }
            if index > 0 { out += "<chord/>" }
            out += "<pitch><step>\(stepName(pitch.step))</step>"
            if pitch.alteration != 0 { out += "<alter>\(alterText(pitch.alteration))</alter>" }
            out += "<octave>\(pitch.octave + 3)</octave></pitch>"
            out += common.duration
            if tiedIn { out += "<tie type=\"stop\"/>" }
            if tieStarts { out += "<tie type=\"start\"/>" }
            out += "<voice>\(voice + 1)</voice>\(event.isCollection && !timed ? "<type>quarter</type>" : common.type)"
            if let accidental { out += "<accidental>\(accidental)</accidental>" }
            out += event.isCollection ? "<stem>none</stem>" : common.modification
            var tied = ""
            if tiedIn { tied += "<tied type=\"stop\"/>" }
            if tieStarts { tied += "<tied type=\"start\"/>" }
            if index == 0 {
                out += marks.isEmpty && tied.isEmpty ? "" : "<notations>\(tied)\(marks)</notations>"
                marks = ""
            } else if !tied.isEmpty {
                out += "<notations>\(tied)</notations>"
            }
            out += "</note>\n"
        }
        state.ties = nextTies
        return out
    }

    /// The duration, type and tuplet ratio every note and rest of an event shares.
    private func timing(_ event: LensMeasuredEvent, voice: Int) -> (duration: String, type: String, modification: String) {
        let duration = event.isGrace ? "" : "<duration>\(max(1, units(event.duration)))</duration>"
        let written = event.writtenDuration
        let type = "<type>\(typeName(written.log))</type>" + String(repeating: "<dot/>", count: written.dots)
        // A two-note tremolo's notes are each written at the pair's length: 2 in the time of 1.
        let pair = event.tremolo?.between == true ? 2 : 1
        guard !event.tuplets.isEmpty || pair > 1 else { return (duration, type, "") }
        let actual = event.tuplets.reduce(pair) { $0 * $1.actualNotes }
        let normal = event.tuplets.reduce(1) { $0 * $1.normalNotes }
        return (duration, type,
                "<time-modification><actual-notes>\(actual)</actual-notes><normal-notes>\(normal)</normal-notes></time-modification>")
    }

    private func notations(_ event: LensMeasuredEvent, post: [String], state: inout VoiceState) -> String {
        var body = ""
        if event.tupletStart { body += "<tuplet type=\"start\"/>" }
        if event.tupletStop { body += "<tuplet type=\"stop\"/>" }
        if post.contains(")"), state.slurOpen {
            body += "<slur type=\"stop\" number=\"1\"/>"
            state.slurOpen = false
        }
        if post.contains("(") {
            body += "<slur type=\"start\" number=\"1\"/>"
            state.slurOpen = true
        }
        if post.contains(where: Self.fermatas.contains) { body += "<fermata/>" }
        let articulations = post.compactMap { Self.articulations[$0] }
        if !articulations.isEmpty {
            body += "<articulations>" + articulations.map { "<\($0)/>" }.joined() + "</articulations>"
        }
        return body
    }

    private static let fermatas: Set<String> = [
        "\\fermata", "\\shortfermata", "\\longfermata", "\\verylongfermata", "\\veryshortfermata",
    ]

    /// LilyPond articulation, with its direction stripped → MusicXML element.
    private static let articulations: [String: String] = [
        ".": "staccato", "\\staccato": "staccato",
        ">": "accent", "\\accent": "accent",
        "-": "tenuto", "\\tenuto": "tenuto",
        "^": "strong-accent", "\\marcato": "strong-accent",
        "!": "staccatissimo", "\\staccatissimo": "staccatissimo",
        "_": "detached-legato", "\\portato": "detached-legato",
        "+": "stopped", "\\stopped": "stopped",
        "\\upbow": "up-bow", "\\downbow": "down-bow", "\\open": "open",
    ]

    /// `-.` → `.`, `^\fermata` → `\fermata`: direction does not matter here.
    private func normalized(_ text: String) -> String {
        guard text.count > 1, let first = text.first, "-^_".contains(first) else { return text }
        return String(text.dropFirst())
    }

    private mutating func flag(_ text: String) {
        if !flags.contains(text) { flags.append(text) }
    }

    private func attributes(
        first: Bool, time: LensTime, clef: LensClef, key: KeySignature,
        previousTime: LensTime?, previousClef: LensClef?, previousKey: KeySignature?
    ) -> String {
        var body = ""
        if first { body += "<divisions>\(LensScoreBuilder.divisions)</divisions>" }
        if first || key != previousKey {
            body += "<key><fifths>\(fifths(for: key))</fifths><mode>\(modeName(key.mode))</mode></key>"
        }
        if first || time != previousTime {
            body += "<time><beats>\(time.beats)</beats><beat-type>\(time.beatType)</beat-type></time>"
        }
        if first || clef != previousClef { body += clefXML(clef) }
        return body.isEmpty ? "" : "      <attributes>\(body)</attributes>\n"
    }

    private func clefXML(_ clef: LensClef) -> String {
        clef.sign == "percussion"
            ? "<clef><sign>percussion</sign></clef>"
            : "<clef><sign>\(clef.sign)</sign><line>\(clef.line)</line></clef>"
    }

    private func units(_ fraction: LensFraction) -> Int {
        fraction.wholeNoteUnits(divisions: LensScoreBuilder.divisions)
    }

    private func typeName(_ log: Int) -> String {
        switch log {
        case -3: return "maxima"
        case -2: return "long"
        case -1: return "breve"
        case 0: return "whole"
        case 1: return "half"
        case 2: return "quarter"
        case 3: return "eighth"
        case 4: return "16th"
        case 5: return "32nd"
        case 6: return "64th"
        case 7: return "128th"
        default: return "quarter"
        }
    }

    private func stepName(_ step: Int) -> String {
        ["C", "D", "E", "F", "G", "A", "B"][max(0, min(6, step))]
    }

    /// Alteration in quarter tones → the MusicXML accidental.
    private func accidentalName(_ alteration: Int) -> String {
        switch alteration {
        case 4: return "double-sharp"
        case -4: return "flat-flat"
        case 3: return "three-quarters-sharp"
        case -3: return "three-quarters-flat"
        case 2: return "sharp"
        case -2: return "flat"
        case 1: return "quarter-sharp"
        case -1: return "quarter-flat"
        default: return "natural"
        }
    }

    /// Quarter tones → semitones, as `1`, `-0.5`, `1.5`.
    private func alterText(_ alteration: Int) -> String {
        let whole = alteration / 2
        guard alteration % 2 != 0 else { return String(whole) }
        let sign = alteration < 0 && whole == 0 ? "-" : ""
        return "\(sign)\(whole).5"
    }

    private func modeName(_ mode: String) -> String {
        let known = ["major", "minor", "ionian", "aeolian", "dorian", "phrygian", "lydian", "mixolydian", "locrian"]
        return known.contains(mode) ? mode : "major"
    }

    /// Fifths in the key signature, from the alterations the key gives
    /// each step: sharps count up, flats down.
    private func fifths(for key: KeySignature) -> Int {
        (0..<7).reduce(0) { total, step in
            let alteration = key.alteration(for: step)
            return total + (alteration > 0 ? 1 : alteration < 0 ? -1 : 0)
        }
    }

    private func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}

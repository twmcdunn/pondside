/// An instrument a staff can be named for: what the score prints, the clef
/// it starts in, and the General MIDI sound the mockup plays it with.
///
/// Scores are concert pitch (DESIGN.md §11): Pondside never writes
/// `\transposition`, so `transposition` is only recorded for parts later.
/// Octave transposers that read better an octave off (guitar, double bass,
/// tenor voice) get the octave clef, which keeps the sounding pitch.
public struct Instrument: Sendable, Hashable, Identifiable {
    public enum Family: String, Sendable, CaseIterable {
        case woodwinds = "Woodwinds", brass = "Brass", percussion = "Percussion", keyboards = "Keyboards"
        case plucked = "Plucked Strings", strings = "Strings", voices = "Voices", electronics = "Electronics"
    }

    public var id: String
    public var name: String
    public var shortName: String
    public var family: Family
    /// The LilyPond clef name, as `\clef` takes it.
    public var clef: String
    /// The General MIDI instrument LilyPond's `midiInstrument` names; nil is
    /// silent (electronics are played by the patch, not the mockup).
    public var midi: String?
    /// The written key for parts (`bf` for a B♭ clarinet); nil sounds as written.
    public var transposition: String?
    /// Lower-case words in a staff name that mean this instrument, longest
    /// and most specific first across the whole catalog.
    var words: [String]
    /// Abbreviations that mean it when they are a whole word: "vln", "fl".
    var abbreviations: [String]

    init(_ id: String, _ name: String, _ shortName: String, _ family: Family, clef: String = "treble",
         midi: String?, transposition: String? = nil, words: [String] = [], abbreviations: [String] = []) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.family = family
        self.clef = clef
        self.midi = midi
        self.transposition = transposition
        self.words = words.isEmpty ? [name.lowercased()] : words
        self.abbreviations = abbreviations
    }
}

extension Instrument {
    /// The catalog, in score order (woodwinds at the top of the page).
    /// Order also decides matching: "piccolo" before "flute", "english
    /// horn" before "horn", "double bass" before "bass".
    public static let catalog: [Instrument] = [
        Instrument("piccolo", "Piccolo", "Picc.", .woodwinds, midi: "piccolo", words: ["piccolo", "ottavino"], abbreviations: ["picc"]),
        Instrument("alto-flute", "Alto Flute", "A. Fl.", .woodwinds, midi: "flute", transposition: "g", words: ["alto flute"]),
        Instrument("bass-flute", "Bass Flute", "B. Fl.", .woodwinds, midi: "flute", transposition: "c", words: ["bass flute"]),
        Instrument("flute", "Flute", "Fl.", .woodwinds, midi: "flute", words: ["flute", "flauto", "flöte", "flûte"], abbreviations: ["fl"]),
        Instrument("oboe", "Oboe", "Ob.", .woodwinds, midi: "oboe", words: ["oboe", "hautbois"], abbreviations: ["ob"]),
        Instrument("english-horn", "English Horn", "E. H.", .woodwinds, midi: "english horn", transposition: "f",
                   words: ["english horn", "cor anglais", "corno inglese"], abbreviations: ["eh", "c.a."]),
        Instrument("bass-clarinet", "Bass Clarinet", "B. Cl.", .woodwinds, clef: "bass", midi: "clarinet", transposition: "bf,",
                   words: ["bass clarinet", "clarinetto basso"], abbreviations: ["bcl", "b.cl."]),
        Instrument("clarinet", "Clarinet in B♭", "Cl.", .woodwinds, midi: "clarinet", transposition: "bf",
                   words: ["clarinet", "clarinetto", "klarinette", "clarinette"], abbreviations: ["cl", "clar"]),
        Instrument("contrabassoon", "Contrabassoon", "Cbsn.", .woodwinds, clef: "bass_8", midi: "bassoon",
                   words: ["contrabassoon", "contrafagotto", "kontrafagott"], abbreviations: ["cbsn", "cfg"]),
        Instrument("bassoon", "Bassoon", "Bsn.", .woodwinds, clef: "bass", midi: "bassoon",
                   words: ["bassoon", "fagotto", "fagott", "basson"], abbreviations: ["bsn", "fg"]),
        Instrument("soprano-sax", "Soprano Saxophone", "S. Sax.", .woodwinds, midi: "soprano sax", transposition: "bf",
                   words: ["soprano sax"]),
        Instrument("alto-sax", "Alto Saxophone", "A. Sax.", .woodwinds, midi: "alto sax", transposition: "ef",
                   words: ["alto sax"], abbreviations: ["asx"]),
        Instrument("tenor-sax", "Tenor Saxophone", "T. Sax.", .woodwinds, midi: "tenor sax", transposition: "bf,",
                   words: ["tenor sax"], abbreviations: ["tsx"]),
        Instrument("baritone-sax", "Baritone Saxophone", "Bar. Sax.", .woodwinds, clef: "bass", midi: "baritone sax",
                   transposition: "ef,", words: ["baritone sax", "bari sax"]),
        Instrument("recorder", "Recorder", "Rec.", .woodwinds, midi: "recorder", words: ["recorder", "flauto dolce", "blockflöte"]),

        Instrument("horn", "Horn in F", "Hn.", .brass, midi: "french horn", transposition: "f",
                   words: ["horn", "corno", "french horn"], abbreviations: ["hn", "cor"]),
        Instrument("trumpet", "Trumpet in C", "Tpt.", .brass, midi: "trumpet",
                   words: ["trumpet", "tromba", "trompete", "trompette"], abbreviations: ["tpt", "tr"]),
        Instrument("bass-trombone", "Bass Trombone", "B. Tbn.", .brass, clef: "bass", midi: "trombone", words: ["bass trombone"]),
        Instrument("trombone", "Trombone", "Tbn.", .brass, clef: "bass", midi: "trombone",
                   words: ["trombone", "posaune"], abbreviations: ["tbn", "trb"]),
        Instrument("tuba", "Tuba", "Tba.", .brass, clef: "bass", midi: "tuba", words: ["tuba"], abbreviations: ["tba"]),

        Instrument("timpani", "Timpani", "Timp.", .percussion, clef: "bass", midi: "timpani",
                   words: ["timpani", "timpano", "pauken"], abbreviations: ["timp"]),
        Instrument("glockenspiel", "Glockenspiel", "Glk.", .percussion, midi: "glockenspiel", words: ["glockenspiel"], abbreviations: ["glk", "glock"]),
        Instrument("xylophone", "Xylophone", "Xyl.", .percussion, midi: "xylophone", words: ["xylophone"], abbreviations: ["xyl"]),
        Instrument("vibraphone", "Vibraphone", "Vib.", .percussion, midi: "vibraphone", words: ["vibraphone"], abbreviations: ["vib"]),
        Instrument("marimba", "Marimba", "Mar.", .percussion, midi: "marimba", words: ["marimba"], abbreviations: ["mar", "mba"]),
        Instrument("crotales", "Crotales", "Crot.", .percussion, midi: "tubular bells", words: ["crotales"]),
        Instrument("tubular-bells", "Tubular Bells", "T. Bells", .percussion, midi: "tubular bells", words: ["tubular bells", "chimes"]),

        Instrument("piano", "Piano", "Pno.", .keyboards, midi: "acoustic grand", words: ["piano", "pianoforte"], abbreviations: ["pno", "pf"]),
        Instrument("celesta", "Celesta", "Cel.", .keyboards, midi: "celesta", words: ["celesta", "celeste"], abbreviations: ["cel"]),
        Instrument("harpsichord", "Harpsichord", "Hpd.", .keyboards, midi: "harpsichord",
                   words: ["harpsichord", "cembalo", "clavecin"], abbreviations: ["hpd", "cemb"]),
        Instrument("organ", "Organ", "Org.", .keyboards, midi: "church organ", words: ["organ", "organo", "orgel", "orgue"], abbreviations: ["org"]),
        Instrument("accordion", "Accordion", "Acc.", .keyboards, midi: "accordion", words: ["accordion", "akkordeon"], abbreviations: ["acc", "accdn"]),

        Instrument("harp", "Harp", "Hp.", .plucked, midi: "orchestral harp", words: ["harp", "arpa", "harfe", "harpe"], abbreviations: ["hp", "hrp"]),
        Instrument("bass-guitar", "Bass Guitar", "B. Gtr.", .plucked, clef: "bass_8", midi: "electric bass (finger)",
                   words: ["bass guitar", "electric bass"]),
        Instrument("electric-guitar", "Electric Guitar", "E. Gtr.", .plucked, clef: "treble_8", midi: "electric guitar (clean)",
                   words: ["electric guitar"]),
        Instrument("guitar", "Guitar", "Gtr.", .plucked, clef: "treble_8", midi: "acoustic guitar (nylon)",
                   words: ["guitar", "chitarra", "gitarre", "guitare"], abbreviations: ["gtr", "git"]),

        Instrument("violin", "Violin", "Vln.", .strings, midi: "violin", words: ["violin", "violino", "violine"],
                   abbreviations: ["vln", "vl", "vn", "vni"]),
        Instrument("viola", "Viola", "Vla.", .strings, clef: "alto", midi: "viola", words: ["viola", "bratsche"],
                   abbreviations: ["vla", "va"]),
        Instrument("cello", "Violoncello", "Vc.", .strings, clef: "bass", midi: "cello", words: ["violoncello", "cello"],
                   abbreviations: ["vc", "vlc"]),
        Instrument("double-bass", "Double Bass", "Db.", .strings, clef: "bass_8", midi: "contrabass",
                   words: ["double bass", "contrabass", "contrabbasso", "kontrabass", "contrebasse"], abbreviations: ["db", "cb", "kb"]),

        Instrument("mezzo", "Mezzo-soprano", "Mez.", .voices, midi: "choir aahs", words: ["mezzo"]),
        Instrument("soprano", "Soprano", "S.", .voices, midi: "choir aahs", words: ["soprano", "sopran"], abbreviations: ["s"]),
        Instrument("alto", "Alto", "A.", .voices, midi: "choir aahs", words: ["alto", "contralto"], abbreviations: ["a"]),
        Instrument("tenor", "Tenor", "T.", .voices, clef: "treble_8", midi: "choir aahs", words: ["tenor", "ténor"], abbreviations: ["t"]),
        Instrument("baritone", "Baritone", "Bar.", .voices, clef: "bass", midi: "choir aahs", words: ["baritone", "bariton"]),
        Instrument("bass-voice", "Bass", "B.", .voices, clef: "bass", midi: "choir aahs", words: ["bass", "basso"], abbreviations: ["b"]),
        Instrument("voice", "Voice", "V.", .voices, midi: "choir aahs", words: ["voice", "voix", "stimme", "voce"]),

        Instrument("electronics", "Electronics", "Elec.", .electronics, midi: nil,
                   words: ["electronic", "elec.", "tape", "live electronics"], abbreviations: ["elec", "elx"]),
    ]

    public static func named(_ id: String) -> Instrument? { catalog.first { $0.id == id } }

    /// The instrument a staff name means, as the mockup reads it: the first
    /// catalog entry with one of its words in the name, else one whose
    /// abbreviation is a whole word of it ("Vln I", "Fl. 2").
    public static func matching(name: String) -> Instrument? {
        let lower = name.lowercased()
        if let hit = catalog.first(where: { i in i.words.contains { lower.contains($0) } }) { return hit }
        let tokens = lower.split { !$0.isLetter && $0 != "." }.map { $0.hasSuffix(".") ? String($0.dropLast()) : String($0) }
        return catalog.first { i in i.abbreviations.contains { a in tokens.contains(a.hasSuffix(".") ? String(a.dropLast()) : a) } }
    }

    /// The instrument whose sound this is, for showing what a staff plays as.
    public static func playing(midi: String) -> Instrument? {
        catalog.first { $0.midi == midi }
    }

    /// The General MIDI sounds LilyPond's `midiInstrument` accepts, in
    /// program order (LilyPond's `instrument-names-alist`).
    public static let midiSounds: [String] = [
        "acoustic grand", "bright acoustic", "electric grand", "honky-tonk", "electric piano 1", "electric piano 2",
        "harpsichord", "clav", "celesta", "glockenspiel", "music box", "vibraphone", "marimba", "xylophone",
        "tubular bells", "dulcimer", "drawbar organ", "percussive organ", "rock organ", "church organ", "reed organ",
        "accordion", "harmonica", "concertina", "acoustic guitar (nylon)", "acoustic guitar (steel)",
        "electric guitar (jazz)", "electric guitar (clean)", "electric guitar (muted)", "overdriven guitar",
        "distorted guitar", "guitar harmonics", "acoustic bass", "electric bass (finger)", "electric bass (pick)",
        "fretless bass", "slap bass 1", "slap bass 2", "synth bass 1", "synth bass 2", "violin", "viola", "cello",
        "contrabass", "tremolo strings", "pizzicato strings", "orchestral harp", "timpani", "string ensemble 1",
        "string ensemble 2", "synthstrings 1", "synthstrings 2", "choir aahs", "voice oohs", "synth voice",
        "orchestra hit", "trumpet", "trombone", "tuba", "muted trumpet", "french horn", "brass section",
        "synthbrass 1", "synthbrass 2", "soprano sax", "alto sax", "tenor sax", "baritone sax", "oboe",
        "english horn", "bassoon", "clarinet", "piccolo", "flute", "recorder", "pan flute", "blown bottle",
        "shakuhachi", "whistle", "ocarina", "lead 1 (square)", "lead 2 (sawtooth)", "lead 3 (calliope)",
        "lead 4 (chiff)", "lead 5 (charang)", "lead 6 (voice)", "lead 7 (fifths)", "lead 8 (bass+lead)",
        "pad 1 (new age)", "pad 2 (warm)", "pad 3 (polysynth)", "pad 4 (choir)", "pad 5 (bowed)",
        "pad 6 (metallic)", "pad 7 (halo)", "pad 8 (sweep)", "fx 1 (rain)", "fx 2 (soundtrack)", "fx 3 (crystal)",
        "fx 4 (atmosphere)", "fx 5 (brightness)", "fx 6 (goblin)", "fx 7 (echoes)", "fx 8 (sci-fi)", "sitar",
        "banjo", "shamisen", "koto", "kalimba", "bagpipe", "fiddle", "shanai", "tinkle bell", "agogo",
        "steel drums", "woodblock", "taiko drum", "melodic tom", "synth drum", "reverse cymbal",
        "guitar fret noise", "breath noise", "seashore", "bird tweet", "telephone ring", "helicopter", "applause",
        "gunshot",
    ]

    /// Clefs offered for a staff, LilyPond names with their labels.
    public static let clefs: [(name: String, label: String)] = [
        ("treble", "Treble"), ("treble_8", "Treble 8vb"), ("treble^8", "Treble 8va"), ("bass", "Bass"),
        ("bass_8", "Bass 8vb"), ("alto", "Alto"), ("tenor", "Tenor"), ("percussion", "Percussion"),
        ("soprano", "Soprano"), ("mezzosoprano", "Mezzo-soprano"), ("baritone", "Baritone"), ("french", "French violin"),
    ]
}

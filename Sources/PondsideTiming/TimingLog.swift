import Foundation

/// What LilyPond reported while engraving: every tempo, cue, mark, note
/// and group at its exact moment. The interpreter is the source of truth
/// (DESIGN.md §5.7): nothing here is guessed from the source text.
///
/// Two line formats are read, both tab-separated:
///
///     <moment> <bar> <kind> <values…>                      timing.ily (.timing files)
///     <moment> <bar> @<measure position> <kind> <values…>  Pondside's dump, adding where
///                                                          in the bar each row is
///
/// Kinds: `tempo <quarters per minute>`, `text <label>` (cues are
/// `text cue N`), `note <staff> <midi>` (Pondside adds the note's source
/// `file line character`, for the playhead), `group <staff> start|stop`,
/// `meter <n>/<d>`, `cnote <staff> <midi> <index>` (a note of a
/// `\collection`, which takes no time and does not sound; DESIGN.md §13).
public struct TimingLog: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case tempo(quartersPerMinute: Double)
            case text(String)
            case note(staff: String, midi: Int)
            case rest(staff: String)
            case group(staff: String, start: Bool)
            /// A note of a `\collection`: its place in the collection.
            case collectionNote(staff: String, midi: Int, index: Int)
            case meter(numerator: Int, denominator: Int)
            /// A Lexicon entry's cue: which entry, how long its music is (whole
            /// notes) and its params as written (a Scheme alist), so its sound
            /// params can be evaluated with real timing.
            case lexicon(cue: String, entry: String, span: Rational, params: String)
        }

        /// Where a text event (a cue, a mark) was written, when known.
        public struct Origin: Sendable, Hashable, Codable {
            public var file: String
            public var line: Int
            /// 0-based Unicode-scalar offset in the line, as point-and-click.
            public var character: Int

            public init(file: String, line: Int, character: Int) {
                self.file = file
                self.line = line
                self.character = character
            }
        }

        public var moment: Rational
        public var bar: Int
        /// Position within the bar, in whole notes, when the dump knows it.
        public var measurePosition: Rational?
        public var kind: Kind
        public var origin: Origin?

        public init(moment: Rational, bar: Int, measurePosition: Rational? = nil, kind: Kind, origin: Origin? = nil) {
            self.moment = moment
            self.bar = bar
            self.measurePosition = measurePosition
            self.kind = kind
            self.origin = origin
        }
    }

    public var rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// Parses a log; lines it can't read are skipped (LilyPond's own
    /// output can share the stream). `prefix` selects tagged lines.
    public init(parsing text: String, prefix: String? = nil) {
        var rows: [Row] = []
        for raw in text.split(separator: "\n") {
            var line = Substring(raw)
            if let prefix {
                guard let r = line.range(of: prefix) else { continue }
                line = line[r.upperBound...]
            }
            var f = line.split(separator: "\t", omittingEmptySubsequences: false).map { String($0) }
            if f.last == "" { f.removeLast() }
            guard f.count >= 3, let moment = Rational(parsing: f[0]), let bar = Int(f[1]) else { continue }
            var i = 2
            var position: Rational?
            if f[i].hasPrefix("@") {
                position = Rational(parsing: f[i].dropFirst())
                i += 1
            }
            guard f.count > i else { continue }
            let values = Array(f[(i + 1)...])
            let kind: Row.Kind
            var origin: Row.Origin?
            switch f[i] {
            case "tempo":
                guard let v = values.first.flatMap(Double.init) else { continue }
                kind = .tempo(quartersPerMinute: v)
            case "text":
                guard let v = values.first else { continue }
                kind = .text(v)
                if values.count >= 4, let line = Int(values[2]), let ch = Int(values[3]) {
                    origin = Row.Origin(file: values[1], line: line, character: ch)
                }
            case "note":
                guard values.count >= 2, let midi = Int(values[1]) else { continue }
                kind = .note(staff: values[0], midi: midi)
                // Pondside's dump adds where the note was written; timing.ily
                // rows (and generated notes) end after the pitch.
                if values.count >= 5, let line = Int(values[3]), let ch = Int(values[4]) {
                    origin = Row.Origin(file: values[2], line: line, character: ch)
                }
            case "rest":
                guard let staff = values.first else { continue }
                kind = .rest(staff: staff)
                if values.count >= 4, let line = Int(values[2]), let ch = Int(values[3]) {
                    origin = Row.Origin(file: values[1], line: line, character: ch)
                }
            case "cnote":
                guard values.count >= 3, let midi = Int(values[1]), let index = Int(values[2]) else { continue }
                kind = .collectionNote(staff: values[0], midi: midi, index: index)
                if values.count >= 6, let line = Int(values[4]), let ch = Int(values[5]) {
                    origin = Row.Origin(file: values[3], line: line, character: ch)
                }
            case "group":
                guard values.count >= 2 else { continue }
                kind = .group(staff: values[0], start: values[1] == "start")
            case "meter":
                // Not a Rational: 6/8 must stay 6/8.
                let p = values.first?.split(separator: "/") ?? []
                guard p.count == 2, let n = Int(p[0]), let d = Int(p[1]), d > 0 else { continue }
                kind = .meter(numerator: n, denominator: d)
            case "lexicon":
                guard values.count >= 4, let span = Rational(parsing: values[2]) else { continue }
                kind = .lexicon(cue: values[0], entry: values[1], span: span, params: values[3...].joined(separator: "\t"))
            default:
                continue
            }
            rows.append(Row(moment: moment, bar: bar, measurePosition: position, kind: kind, origin: origin))
        }
        self.rows = rows
    }

    /// Text rows starting with `prefix`, once per moment and text (every
    /// voice's engraver hears the same event), in score order.
    public func texts(startingWith prefix: String)
        -> [(moment: Rational, bar: Int, measurePosition: Rational?, text: String, origin: Row.Origin?)] {
        var seen = Set<String>()
        var out: [(moment: Rational, bar: Int, measurePosition: Rational?, text: String, origin: Row.Origin?)] = []
        for r in rows {
            guard case .text(let t) = r.kind, t.hasPrefix(prefix) else { continue }
            let key = "\(r.moment) \(t)"
            if seen.insert(key).inserted { out.append((r.moment, r.bar, r.measurePosition, t, r.origin)) }
        }
        return out.sorted { $0.moment < $1.moment }
    }

    /// The piece's end: the `end` mark, else the last row.
    public var end: Rational? {
        let ends = rows.compactMap { r -> Rational? in
            if case .text("end") = r.kind { return r.moment }
            return nil
        }
        return ends.max() ?? rows.map(\.moment).max()
    }

    /// The meter in force at `moment`, if the dump recorded meters.
    public func meter(at moment: Rational) -> (numerator: Int, denominator: Int)? {
        var best: (Rational, Int, Int)?
        for r in rows {
            guard case .meter(let n, let d) = r.kind, r.moment <= moment else { continue }
            if best == nil || r.moment >= best!.0 { best = (r.moment, n, d) }
        }
        return best.map { ($0.1, $0.2) }
    }

    /// Each collection on `staff` (the electronics' `\\collection`s), in
    /// score order: Pondside's `cnote` rows, or older logs' groups.
    public func collections(staff: String) -> [(moment: Rational, bar: Int, midi: [Int])] {
        Collections.find(in: self, staff: staff).map { ($0.moment, $0.bar, $0.midi) }
    }
}

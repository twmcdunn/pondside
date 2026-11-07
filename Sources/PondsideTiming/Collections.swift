import Foundation

/// The pitch collections on one staff (the notes between a `\startGroup`
/// and its `\stopGroup`, as `\collection` writes them), for a patch: the
/// `~ec` and `~ecWhere` arrays the lilypond-supercollider workflow's
/// `piece.ec.scd` has always held, so patches that load it keep working.
public enum Collections {
    public struct Collection: Sendable, Hashable {
        public var moment: Rational
        public var bar: Int
        /// The notes as written, in order.
        public var midi: [Int]
        public var seconds: Double
        /// The last cue at or before it ("cue 7").
        public var cue: String?
        /// The staff's name (`\new Staff = "elecUp"`), empty when it has none.
        public var staff: String = ""
        /// Where in its bar, in whole notes, when the dump knows it.
        public var measurePosition: Rational?

        public var pitchClasses: [Int] { Set(midi.map { (($0 % 12) + 12) % 12 }).sorted() }
    }

    /// The collections on `staff`, in score order. Pondside's dump marks a
    /// collection's notes (`cnote` rows, numbered from 0); older logs
    /// (timing.ily) bracket them with `group` rows instead.
    public static func find(in log: TimingLog, staff: String) -> [Collection] {
        let map = TempoMap(log)
        let cues = log.texts(startingWith: "cue ")
        func make(_ row: TimingLog.Row) -> Collection {
            Collection(moment: row.moment, bar: row.bar, midi: [], seconds: map.seconds(at: row.moment),
                       cue: cues.last { $0.moment <= row.moment }?.text, staff: staff, measurePosition: row.measurePosition)
        }
        // Pondside's rows: index 0 starts a collection. Every voice's engraver
        // hears its own notes only, so each note is reported once.
        var marked: [Collection] = []
        for r in log.rows {
            guard case .collectionNote(let s, let midi, let index) = r.kind, s == staff else { continue }
            if index == 0 || marked.last?.moment != r.moment { marked.append(make(r)) }
            marked[marked.count - 1].midi.append(midi)
        }
        if !marked.isEmpty { return marked.sorted { $0.moment < $1.moment } }

        var byMoment: [Rational: [TimingLog.Row]] = [:]
        for r in log.rows {
            switch r.kind {
            case .note(let s, _) where s == staff, .group(let s, _) where s == staff: byMoment[r.moment, default: []].append(r)
            default: continue
            }
        }
        var out: [Collection] = []
        var current: Collection?
        for m in byMoment.keys.sorted() {
            let rows = byMoment[m]!
            if let start = rows.first(where: { if case .group(_, true) = $0.kind { return true }; return false }) {
                current = make(start)
            }
            for r in rows { if case .note(_, let midi) = r.kind { current?.midi.append(midi) } }
            if let c = current, rows.contains(where: { if case .group(_, false) = $0.kind { return true }; return false }) {
                out.append(c)
                current = nil
            }
        }
        return out
    }

    /// Every staff's collections, in score order (by moment, then by the
    /// order the staves first appear in the log).
    public static func all(in log: TimingLog) -> [Collection] {
        var staves: [String] = []
        for r in log.rows {
            switch r.kind {
            case .collectionNote(let s, _, _), .group(let s, _): if !staves.contains(s) { staves.append(s) }
            default: continue
            }
        }
        let found = staves.enumerated().flatMap { i, s in find(in: log, staff: s).map { (i, $0) } }
        return found.sorted { ($0.1.moment, $0.0) < ($1.1.moment, $1.0) }.map(\.1).filter { !$0.midi.isEmpty }
    }

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// `~ec = [...]; ~ecWhere = [...];` as SuperCollider code.
    public static func scd(_ list: [Collection], staff: String, score: String, variable: String = "ec") -> String {
        func f(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }
        var out = "// Collections on staff \(staff), from \(score) (pondside cues --format ec):\n"
        out += "// pitch classes ascending from C; each line: index: bar, time, last cue: the notes as written.\n"
        out += "~\(variable) = [\n"
        for (i, c) in list.enumerated() {
            let label = "\(i): bar \(c.bar), \(f(c.seconds, 1)) s" + (c.cue.map { ", " + $0 } ?? "") + ": "
                + c.midi.map { names[(($0 % 12) + 12) % 12] }.joined(separator: " ")
            out += "\t[" + c.pitchClasses.map(String.init).joined(separator: ", ") + "]"
                + (i < list.count - 1 ? "," : " ") + "   // " + label + "\n"
        }
        out += "];\n"
        out += "// where each one is in the score (seconds at the render's tempo; cue: the last cue\n"
        out += "// at or before it), e.g. to check that the patch plays it in that cue's window\n"
        let where_ = list.map { c in "(bar: \(c.bar), time: \(f(c.seconds, 3)), cue: " + (c.cue.map { "\"\($0)\"" } ?? "nil") + ")" }
        out += "~\(variable)Where = [\n\t" + where_.joined(separator: ",\n\t") + "\n];\n"
        return out
    }

    /// The score's collections for a patch, every staff's: `~collections`,
    /// in score order, each an Event, and `~collectionsOn[\\staff]`, one
    /// staff's. Pondside writes it beside the mockup's cue times
    /// (`renders/<name>.collections.scd`) and the engine loads it.
    public static func collectionsSCD(_ list: [Collection], score: String) -> String {
        func f(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }
        func symbol(_ s: String) -> String { "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        var out = "// Pitch collections in \(score), written by Pondside after every engraving: don't edit.\n"
        out += "// ~collections: every staff's \\collection, in score order; ~collectionsOn['elecUp']: one staff's.\n"
        out += "// Each is an Event: pcs (pitch classes above C, ascending), midi (as written), staff,\n"
        out += "// bar, time (seconds in the mockup), cue (the last cue at or before it), index.\n"
        out += "~collections = [\n"
        for (i, c) in list.enumerated() {
            out += "\t(index: \(i), staff: \(symbol(c.staff)), bar: \(c.bar), time: \(f(c.seconds, 3)), cue: "
                + (c.cue.map { "\"\($0)\"" } ?? "nil")
                + ", midi: [" + c.midi.map(String.init).joined(separator: ", ") + "]"
                + ", pcs: [" + c.pitchClasses.map(String.init).joined(separator: ", ") + "])"
                + (i < list.count - 1 ? "," : "") + "   // " + c.midi.map { names[(($0 % 12) + 12) % 12] }.joined(separator: " ") + "\n"
        }
        out += "];\n"
        out += "~collectionsOn = IdentityDictionary.new;\n"
        out += "~collections.do { |c| ~collectionsOn[c.staff] = (~collectionsOn[c.staff] ? []).add(c) };\n"
        return out
    }
}
